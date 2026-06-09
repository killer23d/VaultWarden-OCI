You are working in the following repository:

Repository: killer23d/VaultWarden-OCI
Target base branch: Beta

This is Prompt 1 of 2.

Your assignment in this prompt is limited to script optimization, portability,
maintainability, and validation.

Do not update documentation in this prompt, except for generated files that are
unavoidably produced by required validation. If that happens, revert those
documentation changes unless the repository requires generated files to stay
synchronized at every commit.

Do not create a pull request in this prompt.

Stop after the Step 1 validation gate passes and provide the required handoff
output for Prompt 2.

======================================================================
PRIMARY OBJECTIVE
======================================================================

Produce a focused, low-risk script optimization branch that:

- Preserves all currently supported behavior in the `Beta` branch.
- Makes scripts compatible with supported Ubuntu CPU architectures.
- Avoids unnecessary CPU-architecture handling.
- Removes unnecessary cloud-provider coupling from core operations.
- Reduces dead code, duplication, fragile shell patterns, and comment noise.
- Keeps scripts understandable and maintainable by a junior administrator.
- Preserves security, secret handling, storage safety, backup safety, restore
  safety, and network invariants.
- Completes and validates all Step 1 work before any documentation work begins.

The implementation in the current `Beta` branch is the source of truth.

Do not use `main` as the implementation source of truth.

======================================================================
BRANCH SAFETY
======================================================================

All analysis, implementation, validation, and commits must use the current
remote `Beta` branch as their source of truth.

Before changing any files:

1. Fetch all current remote references.
2. Verify that `origin/Beta` exists, using the exact branch name and case.
3. Report the commit SHA currently at `origin/Beta`.
4. Create a dedicated working branch from the current `origin/Beta`.
5. Verify that the working branch merge base is the current `origin/Beta`.
6. Confirm that no work is based on `main`.

Suggested working branch:

    refactor/portable-scripts-and-docs

Required branch commands should be equivalent to:

    git fetch --all --prune
    git switch --create refactor/portable-scripts-and-docs origin/Beta

Do not:

- Base the work on `main`.
- Merge `main` into the working branch.
- Rebase the working branch onto `main`.
- Copy behavior from `main` unless it is already present in `Beta` or is
  strictly required by this assignment.
- Create a pull request in this prompt.

If `origin/Beta` does not exist:

- Do not silently fall back to `main`.
- Do not create a branch from another source.
- Stop implementation.
- Report the available remote branches and the exact branch-name problem.

If `Beta` differs from `main`, preserve the implementation, behavior,
architecture, and conventions of `Beta`.

======================================================================
STRICT SCOPE CONTROL
======================================================================

Stay on task.

Permitted changes in Prompt 1:

- Shell scripts.
- Shell shared libraries.
- Script-related configuration required for portability, correctness, or safe
  operation.
- Tests and validation scripts directly related to the script changes.
- CI checks directly related to script correctness.
- Script help text when it is part of the script source and must remain accurate
  after code changes.

Not permitted in Prompt 1 unless strictly necessary to complete this assignment:

- User-facing documentation updates.
- README updates.
- `docs/` updates.
- Pull-request creation.
- New product features.
- Dependency upgrades.
- Container-image version upgrades.
- Broad security redesigns.
- Network redesigns.
- Replacement of the project’s deployment architecture.
- Refactoring unrelated application configuration.
- Changes made only because another style is preferred.
- Renaming public commands, flags, configuration keys, paths, services,
  networks, volumes, or secrets without a demonstrated correctness need.
- Large rewrites where a smaller and safer change would solve the issue.
- Repository-wide formatting unrelated to modified code.
- Fixing unrelated issues found during the audit.

When an unrelated issue is discovered:

1. Do not fix it.
2. Record it for the Prompt 2 pull-request `Out-of-scope observations` section.
3. Continue only with assigned script work.

Do not commit:

- Temporary planning notes.
- Scratch files.
- Debug logs.
- Test-generated artifacts.
- Decrypted secrets.
- Credentials or API tokens.
- Private keys.
- Backup archives.
- Local environment files.
- Editor-specific files.
- Unrelated generated files.

======================================================================
MANDATORY REPOSITORY INVARIANTS
======================================================================

Before modifying code, inspect and understand the current `Beta` implementation.

Preserve the following behaviors and conventions unless direct code analysis
and repository tests prove that an existing implementation is defective:

- Supported Cloudflare-only deployment behavior.
- Supported direct `acme_http` deployment behavior.
- Docker Compose file-backed secrets.
- Existing network segmentation.
- The `vaultwarden_egress` network convention.
- Existing setup workflows.
- Existing startup and shutdown workflows.
- Existing backup workflows.
- Existing restore workflows.
- Existing maintenance workflows.
- Existing uninstall workflows.
- Existing encrypted-secret handling.
- Existing bootstrap-key recovery.
- Existing break-glass administration workflows.
- Existing firewall and intrusion-prevention behavior.
- Existing public script names.
- Existing command-line flags.
- Existing configuration keys.
- Existing paths and storage layouts.
- Existing exit-code behavior where it forms part of the public interface.
- Existing operator-facing workflows.
- Existing version pins and build-argument wiring.

Do not introduce a `caddy_external` network unless it already exists in the
current `Beta` branch and is required by that branch’s implementation.

Do not update version pins as part of this assignment.

If Vaultwarden 1.36.0 or Caddy 2.11.4 are pinned in the current `Beta` branch,
preserve those pins. If `Beta` uses different pins, preserve the versions
actually present in `Beta`.

Do not weaken:

- Secret isolation.
- File permissions.
- Container hardening.
- Network isolation.
- Firewall controls.
- Backup validation.
- Restore safeguards.
- Destructive-operation confirmations.
- Data-integrity checks.

Code simplification must not reduce security, reliability, diagnostics, or
operator safety.

======================================================================
PROMPT 1 CHECKLIST
======================================================================

Create and maintain this checklist in the agent’s working plan.

Do not add a temporary checklist file to the repository unless the repository
already has an established convention requiring one.

Copy the completed Prompt 1 checklist into the final handoff output.

[P1-A] Repository and branch assessment
- [ ] Fetch all remote references.
- [ ] Verify that `origin/Beta` exists with the exact expected case.
- [ ] Record the current `origin/Beta` commit SHA.
- [ ] Create the working branch from the current `origin/Beta`.
- [ ] Confirm the working branch is not based on `main`.
- [ ] Inspect the working tree for pre-existing user changes.
- [ ] Protect all pre-existing user changes from overwrite or deletion.
- [ ] Identify repository-specific contribution and agent instructions.
- [ ] Identify test, lint, formatting, generation, and CI commands.
- [ ] Inventory executable scripts and sourced shell libraries.
- [ ] Inventory Docker Compose files and overlays.
- [ ] Inventory configuration examples and templates.
- [ ] Identify generated documentation and its source, but do not edit docs.
- [ ] Record current public commands, options, paths, networks, storage
      assumptions, secrets behavior, and deployment modes.
- [ ] Run and record available baseline checks before making changes.
- [ ] Record pre-existing baseline failures separately.

[P1-B] Script optimization
- [ ] Audit scripts for CPU-architecture assumptions.
- [ ] Audit scripts for Ubuntu-platform assumptions.
- [ ] Audit scripts for unnecessary cloud-provider assumptions.
- [ ] Audit generic workflows for mandatory OCI dependencies.
- [ ] Audit scripts for dead code and unreachable branches.
- [ ] Audit scripts for unused variables, constants, and functions.
- [ ] Audit scripts for repeated implementations that should use shared helpers.
- [ ] Audit scripts for fragile or unsafe shell patterns.
- [ ] Audit argument validation and privilege handling.
- [ ] Audit error handling and exit statuses.
- [ ] Audit cleanup traps and temporary-file handling.
- [ ] Audit quoting, word splitting, globbing, and pipeline handling.
- [ ] Audit secret handling and sensitive-file permissions.
- [ ] Audit destructive actions and confirmation safeguards.
- [ ] Audit comments using the required comment policy.
- [ ] Implement the smallest safe set of improvements.
- [ ] Preserve public interfaces and supported workflows.
- [ ] Preserve security and network invariants.
- [ ] Add or update focused tests for changed logic.
- [ ] Run syntax checks.
- [ ] Run static analysis.
- [ ] Run formatting checks where configured.
- [ ] Run existing tests.
- [ ] Run newly added focused tests.
- [ ] Validate Docker Compose configurations.
- [ ] Validate architecture handling where applicable.
- [ ] Validate generic non-OCI operation.
- [ ] Validate preserved OCI behavior where applicable.
- [ ] Review the Step 1 diff for regressions.
- [ ] Review the Step 1 diff for unrelated changes.
- [ ] Complete the Step 1 validation gate.
- [ ] Confirm no documentation work began before the Step 1 gate completed.

If a checklist item is not applicable, mark it explicitly as:

    [x] Not applicable — <brief factual reason>

Do not silently omit checklist items.

======================================================================
INITIAL REPOSITORY ASSESSMENT
======================================================================

Before editing:

1. Read all repository-level instruction files, including applicable:
   - `AGENTS.md`
   - `CONTRIBUTING.md`
   - development documentation
   - CI configuration
   - lint and formatting configuration
   - pull-request templates

2. Confirm:
   - Current remote branch state.
   - Current `origin/Beta` SHA.
   - Working branch name.
   - Working branch base.
   - Working-tree cleanliness.
   - Whether pre-existing user changes are present.

3. Do not overwrite, discard, reset, clean, amend, or silently incorporate
   pre-existing user changes.

4. Inventory relevant files, including at least:
   - Top-level executable shell scripts.
   - Shell libraries under `lib/`.
   - Firewall scripts.
   - Fail2ban and related helper scripts.
   - Backup and restore scripts.
   - Secret-management scripts.
   - Setup and startup scripts.
   - Maintenance and uninstall scripts.
   - Storage-related scripts.
   - Docker Compose files and overlays.
   - Container build files.
   - Configuration examples.
   - Environment templates.
   - Command-reference sources and generators.
   - CI workflows.
   - Repository test and validation scripts.

5. Determine:
   - Which documentation is generated.
   - Which files are authoritative sources.
   - Which commands are public interfaces.
   - Which configuration values are public interfaces.
   - Which deployment modes are supported.
   - Which Ubuntu versions are explicitly supported.
   - Which CPU architectures are currently supported or implied.
   - Where cloud-provider-specific logic exists.
   - Which storage workflows are generic and which are provider-specific.

6. Locate and run available baseline checks, such as:
   - Repository test commands.
   - ShellCheck.
   - shfmt.
   - `bash -n`.
   - Docker Compose validation.
   - documentation generation checks, if required for script validation.
   - secret scanning.
   - CI-equivalent local checks.

7. Record pre-existing failures separately so they are not falsely attributed to
   this change.

Do not modify documentation during the initial assessment.

You may maintain private working notes about documentation mismatches for use
during Prompt 2, but do not commit those notes.

======================================================================
STEP 1 — SCRIPT OPTIMIZATION
======================================================================

Complete all Step 1 work before any documentation work.

----------------------------------------------------------------------
1. CPU AND PLATFORM AGNOSTICISM
----------------------------------------------------------------------

The project is intended to run on Ubuntu.

Ensure scripts do not unnecessarily assume a single CPU architecture or a
single Ubuntu hardware platform.

Important principle:

Do not introduce architecture abstraction unless it is needed.

Preferred order:

1. Avoid architecture detection entirely when Ubuntu packages, package
   repositories, or multi-architecture container images already select the
   correct platform.
2. When Debian or Ubuntu architecture names are required, prefer
   `dpkg --print-architecture` over translating `uname -m`.
3. When an upstream artifact uses different architecture names, perform the
   smallest explicit mapping needed at the artifact-selection boundary.
4. Keep a mapping local when it has only one caller and is easier to understand
   beside the affected download logic.
5. Introduce a shared architecture-mapping function only when the same semantic
   mapping is required by multiple callers or needs a single tested policy.

Target architecture support must include at least the architectures already
supported by the current `Beta` implementation. Where compatible upstream
artifacts exist and repository behavior allows it, ensure deterministic support
for:

- x86_64 / amd64
- aarch64 / arm64

Requirements:

- Avoid architecture detection when the operating system or container runtime
  already handles it.
- Do not create a generic architecture abstraction merely to avoid a short,
  clear `case` statement.
- Do not duplicate identical upstream-specific mappings across scripts.
- Prefer architecture-independent Ubuntu packages.
- Prefer multi-architecture container images.
- Do not hardcode `amd64`, `x86_64`, `arm64`, or `aarch64` in download URLs,
  artifact names, package names, or paths without a clear consumer-specific
  reason.
- Do not assume `uname -m` output matches Debian or Ubuntu package architecture
  naming.
- Where an architecture-specific artifact is downloaded:
  - Map the local architecture to the upstream project’s naming convention.
  - Select the matching artifact.
  - Select the matching checksum.
  - Verify the checksum before installation.
  - Fail clearly for unsupported architectures.
- Do not fall back silently to an artifact for another architecture.
- Do not use CPU-specific compiler flags unless the existing implementation
  strictly requires them.
- Prefer Ubuntu-native and portable Linux interfaces where practical.
- Account for Ubuntu package-manager naming and behavior.
- Account for root and non-root execution.
- Do not claim support for an architecture that was not validated.
- Do not convert working Bash scripts to POSIX shell merely for style.
- Continue using Bash where repository features require Bash.
- Use the repository’s established shebang convention consistently.

Architecture handling must be:

- Avoided when the operating system or container runtime already handles it.
- Explicit and deterministic when required.
- Located near the architecture-sensitive operation unless multiple callers
  benefit from a shared implementation.
- Tested at the level where architecture affects artifact or package selection.
- Accompanied by actionable unsupported-platform errors.

----------------------------------------------------------------------
2. CLOUD AGNOSTICISM
----------------------------------------------------------------------

Make core repository operation independent of a specific infrastructure or
cloud provider.

Core workflows include:

- Installation.
- Setup.
- Startup and shutdown.
- Configuration validation.
- Backup.
- Restore.
- Maintenance.
- Secret management.
- Break-glass administration.
- Uninstallation.
- Disaster recovery.

Requirements:

- Core scripts must not require OCI metadata services.
- Core scripts must not require OCI CLI.
- Core scripts must not require OCI APIs.
- Core scripts must not require OCI-specific device paths.
- Core scripts must not assume OCI instance metadata.
- Preserve existing optional OCI behavior.
- Keep provider-specific behavior behind clearly named optional helpers or
  explicit branches.
- Detect capabilities rather than inferring them from a provider name.
- Do not silently detect and modify cloud resources.
- Do not introduce dependencies on another cloud provider.
- Do not replace OCI assumptions with AWS, Azure, GCP, or another provider’s
  assumptions.
- Avoid hardcoded:
  - regions
  - availability domains
  - instance identifiers
  - provider metadata endpoints
  - provider-specific mount paths
  - provider-specific block-device paths
- Keep provider examples clearly separated from generic instructions.
- Generic workflows must operate on an operator-supplied Ubuntu host.
- Generic storage workflows must operate on an operator-supplied block device
  or mounted filesystem.
- Do not assume a block-device name.
- Validate devices, filesystems, mount points, ownership, and free space before
  storage-sensitive operations.
- Do not format, repartition, overwrite, or destructively mount a device without:
  - an explicit operator action
  - a clear warning
  - validation of the selected device
  - an existing or newly justified confirmation safeguard
- Preserve compatibility with non-cloud Ubuntu systems where practical,
  including virtual machines and physical hosts.

Cloud agnostic does not mean removing useful OCI support or OCI examples.

It means generic project operation must not depend on OCI.

----------------------------------------------------------------------
3. DEAD CODE, REDUNDANCY, AND MAINTAINABILITY
----------------------------------------------------------------------

Review the scripts as a single operational system rather than isolated files.

Audit for:

- Dead functions.
- Unreachable branches.
- Unused variables.
- Unused constants.
- Obsolete feature flags.
- Duplicate functions.
- Duplicate validation logic.
- Duplicate logging logic.
- Duplicate error handling.
- Duplicate privilege checks.
- Duplicate dependency checks.
- Duplicate Docker detection.
- Duplicate Docker Compose detection.
- Duplicate path resolution.
- Duplicate configuration parsing.
- Duplicate architecture handling.
- Duplicate secret-handling logic.
- Duplicate storage validation.
- Duplicate backup validation.
- Duplicate restore validation.
- Obsolete compatibility branches.
- Commands whose results are ignored unintentionally.
- Inconsistent return codes.
- Inconsistent exit codes.
- Traps that do not execute as intended.
- Cleanup handlers that hide the original failure.
- Temporary-file leaks.
- Unsafe temporary paths.
- Unquoted variables.
- Accidental word splitting.
- Accidental pathname expansion.
- Unsafe use of `eval`.
- Unsafe parsing of command output.
- Pipelines whose failures are hidden.
- Fragile `grep`, `sed`, `awk`, `cut`, or `find` usage.
- TOCTOU risks.
- Symlink risks around privileged paths.
- Functions with hidden global side effects.
- Libraries that perform actions merely because they were sourced.
- Repeated code that should use an existing shared library.
- Helpers that are overly generic or harder to understand than the code they
  replace.

Optimization rules:

- Remove code only after proving that it is unused.
- Use repository-wide searches and call-site analysis before removing a
  function, variable, branch, or option.
- Consider generated documentation and indirect dispatch before declaring code
  unused.
- Do not remove a branch merely because it is uncommon.
- Do not remove compatibility behavior without evidence that it is obsolete.
- Prefer existing shared libraries over parallel abstractions.
- Consolidate genuinely duplicated logic where doing so reduces defects.
- Do not create a generalized framework for a small amount of duplication.
- Keep functions focused.
- Use clear and operationally meaningful function names.
- Preserve stable public behavior.
- Avoid cosmetic churn.
- Avoid unrelated reordering.
- Maintain setup and maintenance idempotency.
- Preserve useful diagnostics.
- Improve diagnostics where they are vague or non-actionable.
- Error messages should state:
  - what failed
  - the relevant resource or path
  - what the administrator should check or do next

Do not add strict shell options blindly.

Before adding or changing any of the following, analyze control flow and sourced
library behavior:

- `set -e`
- `set -u`
- `set -o pipefail`
- `set -E`
- `inherit_errexit`

A non-zero status may be intentionally used for conditions and feature
detection. Do not break those flows.

----------------------------------------------------------------------
4. COMMENT PRUNING AND COMMENT QUALITY
----------------------------------------------------------------------

Prune and rewrite comments carefully.

The goal is not to minimize the number of comments.

The goal is to retain concise comments that help reviewers and junior
administrators understand intent, operational phases, risks, and invariants.

Retain or improve comments that:

- Separate major phases.
- Separate operational steps.
- Identify the purpose of a function.
- Explain why a non-obvious implementation is required.
- Explain a security-sensitive operation.
- Explain compatibility handling.
- Explain an unusual shell construct.
- Document an invariant.
- Document a side effect.
- Explain why a seemingly redundant check is required.
- Prevent a code reviewer from incorrectly reporting a false positive.
- Help a junior administrator safely maintain the project.
- Help diagnose a failure.
- Help recover from a failure.
- Warn about destructive or irreversible operations.
- Explain provider-specific behavior.
- Explain architecture mapping.
- Explain backup or restore safety requirements.
- Explain why execution order matters.

Remove or rewrite comments that:

- Merely restate the next command.
- Narrate obvious syntax.
- Describe code that no longer exists.
- Contain outdated implementation details.
- Contain incorrect paths or command names.
- Repeat the same explanation in multiple locations.
- Are excessively conversational.
- Include abandoned TODO items without actionable context.
- Include historical commentary that belongs in Git history.
- Are so long that they obscure the code.
- Describe intended behavior that the code does not implement.

Comment style requirements:

- Preserve concise phase headers.
- Use phase headers consistently.
- Place comments next to the relevant logic.
- Explain “why,” constraints, risk, or invariants rather than narrating “what.”
- Use complete, direct language.
- Keep comments accurate after refactoring.
- Do not remove comments solely to reduce line count.
- Do not add comments as a substitute for clear code.
- Preserve comments needed to prevent false-positive review findings.
- Keep comments useful to both maintainers and junior administrators.

----------------------------------------------------------------------
5. SHELL SAFETY AND OPERATOR USABILITY
----------------------------------------------------------------------

For every affected script, verify:

- Arguments are validated before side effects.
- Required commands are checked before use.
- Missing dependencies produce actionable errors.
- Privilege requirements are explicit.
- Privilege elevation is not performed unexpectedly.
- Paths are safely validated where necessary.
- Temporary files use safe creation mechanisms such as `mktemp`.
- Temporary files and directories are removed reliably.
- Cleanup preserves the original exit status.
- Secret values are never printed or logged.
- Sensitive files receive restrictive permissions.
- Destructive actions use existing confirmation or force mechanisms.
- New confirmation behavior does not break automation without justification.
- Non-interactive execution remains supported where currently supported.
- Terminal-only features do not break redirected or automated execution.
- `--help` output remains accurate.
- Help output follows current repository conventions.
- Dry-run behavior remains free of side effects where supported.
- Errors are written to stderr.
- Exit codes remain meaningful.
- Filenames containing spaces do not break affected operations.
- Globs do not accidentally operate on literal patterns.
- Root-owned files are not unintentionally created in a normal user’s home.
- Signal handling does not leave partially written state.
- Atomic writes are used where required for critical configuration.
- Backup operations fail safely.
- Restore operations fail safely.
- Failed validation prevents destructive follow-on steps.
- Operator messages identify the next safe action.
- Scripts remain understandable to a junior Ubuntu administrator.

Do not expose:

- Credentials.
- Tokens.
- SOPS values.
- Encryption keys.
- Bootstrap keys.
- Private-key material.
- Backup encryption secrets.
- Secret file contents.

----------------------------------------------------------------------
6. TESTING CHANGED SCRIPT BEHAVIOR
----------------------------------------------------------------------

Add focused tests when the existing suite does not cover changed
behavior-sensitive logic.

Prioritize tests for:

- Architecture handling where applicable.
- Unsupported architecture handling.
- Artifact-name selection.
- Checksum selection.
- Provider-neutral behavior.
- Optional OCI branches.
- Device and mount-point validation.
- Path handling.
- Argument validation.
- Exit statuses.
- Cleanup behavior.
- Dry-run behavior.
- Secret redaction.
- Shared helper refactoring, but only when shared helpers are actually added or
  changed.

Tests should:

- Avoid real cloud APIs.
- Avoid real production storage.
- Avoid formatting real block devices.
- Avoid using real secrets.
- Avoid network access where practical.
- Use temporary directories.
- Use fixtures or mocked commands.
- Be deterministic.
- Fail with useful diagnostics.
- Match the repository’s current testing style.

Do not add a large test framework solely for this task unless no practical
testing mechanism exists.

----------------------------------------------------------------------
7. STEP 1 VALIDATION GATE
----------------------------------------------------------------------

Before ending Prompt 1:

- Run ShellCheck on every applicable shell script.
- Run shfmt in check mode if shfmt is part of the repository workflow.
- Run `bash -n` against all applicable Bash scripts.
- Run all existing automated tests.
- Run all newly added focused tests.
- Run repository lint and validation commands.
- Validate Docker Compose files and supported overlays with
  `docker compose config`.
- Validate all supported deployment modes.
- Exercise `--help` paths where available.
- Exercise version or status paths where available.
- Exercise configuration-validation paths where available.
- Exercise dry-run paths where available.
- Test architecture handling where applicable with representative values:
  - `x86_64`
  - `amd64`
  - `aarch64`
  - `arm64`
  - at least one unsupported architecture
- Verify unsupported architectures fail clearly where architecture-specific
  handling exists.
- Verify generic operation has no mandatory OCI dependency.
- Verify preserved optional OCI behavior logically and through tests where
  practical.
- Verify Cloudflare-only behavior remains intact.
- Verify direct `acme_http` behavior remains intact.
- Verify file-backed secrets remain intact.
- Verify network segmentation remains intact.
- Verify the expected egress network remains intact.
- Verify no unintended `caddy_external` network was introduced.
- Verify existing version pins remain unchanged.
- Review the entire Step 1 diff.
- Confirm the diff contains no unrelated changes.
- Confirm no documentation files were intentionally edited during Step 1.

If a required validation generated documentation changes, revert those generated
changes unless the repository workflow requires them to remain synchronized at
every commit.

Do not begin Step 2.

Do not create a pull request.

When an existing unrelated baseline failure remains:

- Identify it as pre-existing.
- Include the baseline and final result.
- Demonstrate that the script changes did not worsen it.
- Do not claim that the check passed.

======================================================================
PROMPT 1 COMMITS
======================================================================

Create logical commits for Step 1 only.

Suggested commit messages:

    refactor: improve script portability and maintainability
    test: cover script portability and safety helpers

Use the actual commit messages that best describe the final diff.

Do not create documentation commits in Prompt 1.

Before ending:

1. Fetch the latest `origin/Beta`.
2. Determine whether `Beta` advanced.
3. Rebase or otherwise update the working branch against `origin/Beta` using
   the repository’s accepted workflow.
4. Do not update against `main`.
5. Resolve conflicts by preserving `Beta` behavior.
6. Rerun all affected validation.
7. Confirm a clean working tree.
8. Confirm the merge base is current.
9. Do not push if repository workflow expects Prompt 2 to push; otherwise push
   the Step 1 branch if needed for continuity.

======================================================================
PROMPT 1 COMPLETION CONDITIONS
======================================================================

Prompt 1 is complete only when:

- `origin/Beta` was verified before implementation.
- The working branch was created from the current `origin/Beta`.
- The work was not based on `main`.
- Step 1 was fully implemented.
- Step 1 passed its validation gate.
- No documentation work was started.
- Script behavior remains compatible with supported `Beta` workflows.
- Core operation is not unnecessarily coupled to OCI.
- Optional OCI behavior remains supported.
- Architecture handling is minimal, deterministic, and tested where applicable.
- Unsupported architectures fail clearly where architecture-specific handling
  exists.
- Security controls were not weakened.
- Tests and validation were run and reported honestly.
- The working branch was synchronized with the latest `origin/Beta`.
- Prompt 1 handoff output is complete.

======================================================================
PROMPT 1 FINAL HANDOFF OUTPUT
======================================================================

Before ending, output the following for use in Prompt 2:

## Prompt 1 Handoff

- Repository:
- Working branch name:
- Base branch:
- Original `origin/Beta` SHA:
- Final `origin/Beta` SHA after synchronization:
- Head SHA after Step 1 commits:
- Commit summary:
- Script files changed:
- Test files changed:
- Other non-documentation files changed:
- Documentation files intentionally changed:
  - Must be `None`, unless generated documentation was unavoidable and required
    by repository workflow.
- Pre-existing baseline failures:
- Validation commands run:
- Validation results:
- Checks that could not be run:
- Substitute validation used:
- Out-of-scope observations for Prompt 2 PR body:
- Confirmation that Step 1 validation gate passed:
- Confirmation that Step 2 has not started:
- Completed Prompt 1 checklist:

Do not proceed to documentation work.
Do not create a pull request.
