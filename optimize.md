You are working in the following repository:

Repository: killer23d/VaultWarden-OCI
Target base branch: Beta

Your assignment consists of two strictly sequential tasks:

1. Optimize and improve the portability and maintainability of the repository’s
   scripts.
2. Only after Task 1 is fully completed and validated, update all user-facing
   documentation to accurately describe the resulting repository.

After completing and validating both tasks, create a pull request targeting the
`Beta` branch.

Do not work on unrelated features, dependency upgrades, architectural
redesigns, speculative improvements, or issues outside this assignment.

======================================================================
PRIMARY OBJECTIVE
======================================================================

Produce a focused, reviewable, low-risk pull request that:

- Preserves all currently supported behavior in the `Beta` branch.
- Makes the scripts compatible with supported Ubuntu CPU architectures.
- Removes unnecessary cloud-provider coupling from core operations.
- Reduces dead code, duplication, fragile shell patterns, and comment noise.
- Keeps scripts understandable and maintainable by a junior administrator.
- Updates all relevant documentation to match the final implementation.
- Provides accurate setup, operation, maintenance, troubleshooting, backup,
  restore, and disaster-recovery instructions.
- Adds block-storage usage to the README Quick Start section.
- Includes an auditable checklist showing that every requirement was completed.
- Targets `Beta`, not `main`.

The implementation in the current `Beta` branch is the source of truth.

Documentation must describe what the repository actually does after the script
work is complete. Do not document planned, assumed, aspirational, or
unimplemented behavior.

======================================================================
BRANCH SAFETY
======================================================================

All analysis, implementation, validation, commits, and documentation updates
must use the current remote `Beta` branch as their source of truth.

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
- use documentation or behavior from `main` as the source of truth.
- Create the final pull request against `main`.

If `origin/Beta` does not exist:

- Do not silently fall back to `main`.
- Do not create a branch from another source.
- Stop implementation.
- Report the available remote branches and the exact branch-name problem.

If `Beta` differs from `main`, preserve the implementation, behavior,
architecture, and documentation conventions of `Beta`.

Before completing the assignment, inspect the final pull request metadata and
explicitly confirm:

    Base: Beta
    Head: refactor/portable-scripts-and-docs

Use the actual head branch name if a different working branch was necessary.

======================================================================
STRICT SCOPE CONTROL
======================================================================

Stay on task.

Permitted changes:

- Shell scripts and their shared libraries.
- Script-related configuration required for portability, correctness, or safe
  operation.
- Tests and validation scripts directly related to the script changes.
- CI checks directly related to script correctness or documentation validation.
- README files and other user-facing documentation.
- Documentation generators and their sources.
- Generated command references, but only through the repository’s supported
  generation process.
- Examples and sample configuration that must be synchronized with the scripts.

Not permitted unless strictly necessary to complete this assignment:

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
2. Record it under a non-blocking `Out-of-scope observations` section in the
   pull-request description.
3. Continue only with the assigned work.

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
MANDATORY WORKING CHECKLIST
======================================================================

At the beginning of the task, create and maintain the checklist below in the
agent’s working plan.

Do not add a temporary checklist file to the repository unless the repository
already has an established convention requiring one.

Update the checklist as work progresses.

Copy the final completed checklist into the pull-request description.

Repository and branch assessment
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
- [ ] Inventory user-facing documentation.
- [ ] Identify generated documentation and its source.
- [ ] Record current public commands, options, paths, networks, storage
      assumptions, secrets behavior, and deployment modes.
- [ ] Run and record available baseline checks before making changes.
- [ ] Record pre-existing baseline failures separately.

Step 1 — script optimization
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
- [ ] Validate architecture-normalization behavior.
- [ ] Validate generic non-OCI operation.
- [ ] Validate preserved OCI behavior where applicable.
- [ ] Review the Step 1 diff for regressions.
- [ ] Review the Step 1 diff for unrelated changes.
- [ ] Complete the Step 1 validation gate.
- [ ] Confirm no documentation work began before the Step 1 gate completed.

Step 2 — documentation
- [ ] Begin documentation edits only after Step 1 is complete and validated.
- [ ] Inventory all documentation and documentation-like operator guidance.
- [ ] Identify generated files before editing.
- [ ] Update documentation from the final implementation.
- [ ] Preserve the repository’s existing documentation tone and structure.
- [ ] Verify every documented command and option.
- [ ] Verify every documented path and configuration key.
- [ ] Verify prerequisites and privilege requirements.
- [ ] Update setup and deployment instructions.
- [ ] Update routine operation instructions.
- [ ] Update maintenance instructions.
- [ ] Update secret-management instructions.
- [ ] Update backup instructions.
- [ ] Update restore instructions.
- [ ] Update disaster-recovery instructions.
- [ ] Update bootstrap-key recovery instructions.
- [ ] Update troubleshooting guidance.
- [ ] Add block-storage usage to the README Quick Start.
- [ ] Clearly separate generic storage preparation from provider attachment.
- [ ] Preserve optional OCI-specific guidance without making OCI mandatory.
- [ ] Check and repair internal links and cross-references.
- [ ] Regenerate generated documentation through its supported generator.
- [ ] Review documentation for junior-administrator usability.
- [ ] Confirm documentation does not claim unsupported behavior.
- [ ] Confirm documentation reflects `Beta`, not `main`.

Final validation and pull request
- [ ] Run the complete validation suite after all changes.
- [ ] Run shell static analysis against every applicable shell file.
- [ ] Run syntax checks against every applicable shell file.
- [ ] Run formatting validation where configured.
- [ ] Validate Docker Compose for every supported deployment mode.
- [ ] Validate generated documentation is current.
- [ ] Validate Markdown and links where tooling exists.
- [ ] Search for stale names, commands, paths, networks, and configuration keys.
- [ ] Search for accidentally committed secrets or private data.
- [ ] Run `git diff --check`.
- [ ] Review executable permissions.
- [ ] Review the complete diff for scope compliance.
- [ ] Confirm no changes were unintentionally copied from `main`.
- [ ] Rebase or update against the current `origin/Beta` if required.
- [ ] Rerun affected validation after branch synchronization.
- [ ] Create logical commits.
- [ ] Push the dedicated working branch.
- [ ] Create the pull request with `Beta` as the base branch.
- [ ] Inspect and confirm the PR’s base and head branches.
- [ ] Include the completed checklist in the PR body.
- [ ] Include validation evidence in the PR body.
- [ ] Include risks, limitations, and out-of-scope observations.
- [ ] Return the pull-request URL.

Do not declare the assignment complete while any applicable checklist item
remains unchecked.

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
   - README files.
   - All files under `docs/`.
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
   - documentation generation checks.
   - Markdown lint.
   - link checking.
   - secret scanning.
   - CI-equivalent local checks.

7. Record pre-existing failures separately so they are not falsely attributed to
   this change.

Do not modify documentation during the initial assessment.

You may maintain private working notes about documentation mismatches for use
during Step 2, but do not commit those notes.

======================================================================
STEP 1 — SCRIPT OPTIMIZATION
======================================================================

Complete all Step 1 work before editing documentation.

----------------------------------------------------------------------
1. CPU AND PLATFORM AGNOSTICISM
----------------------------------------------------------------------

The project is intended to run on Ubuntu.

Ensure scripts do not unnecessarily assume a single CPU architecture or a
single Ubuntu hardware platform.

Target architecture support must include at least the architectures already
supported by the current `Beta` implementation. Where compatible upstream
artifacts exist and repository behavior allows it, ensure deterministic support
for:

- x86_64 / amd64
- aarch64 / arm64

Requirements:

- Normalize architecture names through one shared and tested helper when
  architecture-specific handling is required.
- Do not duplicate architecture mapping across scripts.
- Prefer architecture-independent Ubuntu packages.
- Prefer multi-architecture container images.
- Do not hardcode `amd64`, `x86_64`, `arm64`, or `aarch64` in download URLs,
  artifact names, package names, or paths without using normalized architecture
  resolution.
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

Architecture detection must be:

- Explicit.
- Deterministic.
- Centralized where practical.
- Testable.
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

- Architecture normalization.
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
- Shared helper refactoring.

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

Before proceeding to Step 2:

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
- Test architecture normalization with representative values:
  - `x86_64`
  - `amd64`
  - `aarch64`
  - `arm64`
  - at least one unsupported architecture
- Verify unsupported architectures fail clearly.
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

If a required validation generated documentation changes, revert those
generated changes until Step 2 unless the repository workflow requires them to
remain synchronized at every commit.

Do not begin Step 2 until the Step 1 validation gate passes.

When an existing unrelated baseline failure remains:

- Identify it as pre-existing.
- Include the baseline and final result.
- Demonstrate that the pull request did not worsen it.
- Do not claim that the check passed.

======================================================================
STEP 2 — DOCUMENTATION UPDATE
======================================================================

Begin Step 2 only after Step 1 has been implemented, reviewed, and validated.

Documentation must be based on the resulting working branch derived from
`Beta`.

Do not use `main` documentation as the source of truth.

----------------------------------------------------------------------
1. DOCUMENTATION INVENTORY
----------------------------------------------------------------------

Inspect every source of operator-facing guidance, including:

- Root README files.
- All Markdown files under `docs/`.
- Markdown files elsewhere in the repository.
- Script `--help` output.
- Usage text embedded in scripts.
- Example configuration files.
- Environment templates.
- Docker Compose comments containing operator instructions.
- Setup instructions.
- Deployment instructions.
- Storage instructions.
- Backup instructions.
- Restore instructions.
- Disaster-recovery instructions.
- Bootstrap-key recovery instructions.
- Secret-management instructions.
- Maintenance instructions.
- Troubleshooting instructions.
- Uninstall instructions.
- Security and operational notes.
- Generated command references.
- Documentation-generation scripts.
- Non-Markdown files that function as user manuals.

Identify generated documentation before editing.

For generated documentation:

1. Find the authoritative source.
2. Update the authoritative source.
3. Run the supported generator.
4. Commit the regenerated output.
5. Verify generated output is reproducible.

Do not manually edit generated files unless the repository explicitly requires
manual maintenance.

Do not rewrite historical changelog entries.

Only add a changelog entry when the current `Beta` branch convention requires
one for this type of pull request.

----------------------------------------------------------------------
2. DOCUMENTATION STYLE
----------------------------------------------------------------------

Maintain the documentation style already used by the current `Beta` branch,
including:

- Tone.
- Heading hierarchy.
- Level of detail.
- Formatting.
- Terminology.
- Command-example style.
- Warning style.
- Cross-reference style.
- Table style.
- File-name conventions.

Improve accuracy and clarity without replacing the documentation with a
different writing style.

The target reader is a junior system administrator responsible for:

- Initial setup.
- Deployment.
- Routine operation.
- Maintenance.
- Monitoring.
- Troubleshooting.
- Secret handling.
- Backup creation.
- Backup verification.
- Restore testing.
- Full disaster recovery.
- Service reinstallation.
- Storage recovery.

For every documented instruction:

- Verify the command exists.
- Verify command spelling.
- Verify supported flags.
- Verify argument order.
- Verify the referenced file exists.
- Verify the referenced path.
- Verify configuration-key names.
- Verify privileges required.
- Verify prerequisites.
- Verify expected effects.
- Verify warnings are placed before dangerous commands.
- Verify the instruction matches the final implementation.
- Distinguish mandatory steps from optional integrations.
- Distinguish generic operation from OCI-specific operation.
- Avoid undocumented assumptions.
- Avoid statements such as “simply,” “obviously,” or “just.”
- Do not include real credentials, domains, IP addresses, UUIDs, secrets, or
  keys.
- Use unmistakable placeholders.
- Ensure examples are safe to copy after placeholders are replaced.

----------------------------------------------------------------------
3. REQUIRED DOCUMENTATION COVERAGE
----------------------------------------------------------------------

Ensure the final documentation accurately covers the following areas where
supported by the current `Beta` implementation.

Installation and prerequisites
- Supported Ubuntu versions.
- Supported CPU architectures.
- Required packages.
- Required privileges.
- Docker prerequisites.
- Docker Compose prerequisites.
- DNS prerequisites.
- TLS prerequisites.
- Firewall prerequisites.
- Network prerequisites.
- Generic cloud-neutral installation.
- Optional OCI-specific considerations.
- Cloudflare-only deployment.
- Direct `acme_http` deployment.

Configuration
- Configuration files.
- Configuration precedence.
- Environment templates.
- Encrypted-secret workflows.
- Docker Compose file-backed secrets.
- Secret file ownership.
- Secret file permissions.
- Network relationships.
- Service relationships.
- Storage locations.
- Storage configuration.
- Configuration-validation commands.

Routine operations
- Start.
- Stop.
- Restart.
- Status.
- Log inspection.
- Configuration validation.
- Maintenance workflows.
- Secret editing.
- Secret rotation.
- Break-glass administration.
- Existing update-related commands, without inventing a new upgrade policy.

Backup
- Backup creation.
- Backup destination.
- Backup contents.
- Backup exclusions.
- Encryption requirements.
- Required keys and secrets.
- Backup integrity checks.
- Retention behavior.
- Off-host storage recommendations.
- Backup verification.
- Safe backup testing.

Restore
- Restore prerequisites.
- Required backup material.
- Required keys and secrets.
- Restore sequencing.
- Restore validation.
- Ownership and permission restoration.
- Service startup sequencing.
- Post-restore checks.
- Recovery from incomplete restores.
- Recovery from failed restores.
- Differences between in-place restore and replacement-host recovery.

Disaster recovery
- Required off-host materials.
- Required bootstrap keys.
- Required encrypted-secret files.
- Required backup data.
- Preparing a replacement Ubuntu host.
- Reinstalling prerequisites.
- Reattaching existing storage.
- Preparing replacement storage.
- Restoring configuration.
- Restoring application data.
- Restoring permissions.
- Restoring mounts.
- Validating persistent mount configuration.
- Starting services in the correct order.
- DNS considerations.
- TLS considerations.
- Ingress considerations.
- Post-recovery health checks.
- Functional validation.
- Testing recovery without damaging production.
- Differences between a backup restore and full host disaster recovery.

Troubleshooting
- Common failure symptoms.
- Relevant logs.
- Diagnostic commands.
- Permission failures.
- Ownership failures.
- Docker failures.
- Docker Compose failures.
- Storage failures.
- Mount failures.
- Filesystem-capacity failures.
- TLS failures.
- DNS failures.
- Firewall failures.
- Secret-decryption failures.
- Bootstrap-key failures.
- Backup failures.
- Restore failures.
- Unsupported-architecture errors.
- Safe remediation steps.
- Escalation information where appropriate.

Uninstallation
- What is removed.
- What is preserved.
- Backup requirements before removal.
- Confirmation safeguards.
- Storage implications.
- Secret implications.
- Recovery limitations.

----------------------------------------------------------------------
4. README QUICK START — BLOCK STORAGE
----------------------------------------------------------------------

The README Quick Start must include block-storage usage.

Keep the Quick Start concise, operationally safe, and appropriate for a junior
administrator.

Provide a clear path for:

1. Provisioning or attaching storage through the operator’s chosen
   infrastructure provider.
2. Identifying the resulting block device from Ubuntu.
3. Confirming that the selected device is not the operating-system disk.
4. Checking whether the device already contains:
   - a partition table
   - a filesystem
   - mounted data
   - data that must be preserved
5. Creating a filesystem only when explicitly required.
6. Creating the intended mount point.
7. Mounting the filesystem.
8. Obtaining the filesystem UUID.
9. Configuring a persistent mount using the filesystem UUID rather than an
   unstable `/dev/...` path where appropriate.
10. Safely validating the persistent mount configuration.
11. Setting the ownership and permissions expected by the repository.
12. Pointing the project’s supported storage setting or path at that mount.
13. Running the repository’s setup or validation command.
14. Verifying the resulting mount.
15. Verifying available space.
16. Verifying that application data uses the intended location.
17. Linking to detailed storage, backup, restore, and disaster-recovery
    documentation.

Block-storage safety requirements:

- Do not assume `/dev/sdb`.
- Do not assume `/dev/vdb`.
- Do not assume an OCI-specific device path.
- Do not assume a partition number.
- Use discovery tools such as `lsblk`, `findmnt`, and `blkid` appropriately.
- Tell the operator to confirm the device identity before any destructive step.
- Warn that formatting destroys existing data.
- Place the warning immediately before any formatting example.
- Do not present a formatting command as universally required.
- Do not suggest mounting over a non-empty directory without checking it.
- Do not use a real production UUID in examples.
- Do not use real production paths in examples.
- Do not imply that mounting a volume replaces backups.
- Do not imply that provider-side attachment is handled by generic Ubuntu
  commands.
- Clearly distinguish:
  - Provider-side provisioning and attachment.
  - Ubuntu block-device discovery.
  - Filesystem preparation.
  - Persistent mounting.
  - Project storage configuration.
- Keep detailed explanations in the appropriate deployment or storage document
  and link to them from the Quick Start.

Generic instructions must work on Ubuntu independently of the hosting provider.

OCI-specific attachment examples may remain, but they must be placed in a
separate, clearly labeled optional subsection.

----------------------------------------------------------------------
5. JUNIOR-ADMINISTRATOR USABILITY
----------------------------------------------------------------------

Review the documentation as though the reader:

- Understands basic Ubuntu administration.
- Can use SSH and a shell.
- Can copy and edit configuration files.
- May not understand the repository’s internal architecture.
- May not know Docker networking internals.
- May not know SOPS or secret-file behavior.
- May not know how block-device names differ by provider.
- May be responding to an outage under time pressure.

Documentation should therefore:

- State prerequisites before commands.
- State expected outcomes after significant commands.
- Identify destructive steps clearly.
- Explain how to validate success.
- Explain how to stop safely when validation fails.
- Provide diagnostic commands near failure-prone steps.
- Use consistent terms.
- Define repository-specific terms on first use.
- Avoid relying on undocumented tribal knowledge.
- Provide cross-links rather than duplicating long procedures.
- Clearly distinguish routine maintenance from disaster recovery.
- Clearly distinguish a data restore from a full rebuild.

Do not over-explain basic shell syntax.

Focus explanations on project-specific behavior, safety, and recovery.

----------------------------------------------------------------------
6. DOCUMENTATION VALIDATION
----------------------------------------------------------------------

After updating documentation:

- Compare all documented commands against actual argument parsing.
- Compare all documented commands against `--help` output.
- Verify all referenced files exist.
- Verify all referenced paths.
- Verify all configuration keys.
- Verify all service names.
- Verify all Docker network names.
- Verify all Docker volume names.
- Verify all secret names.
- Verify all deployment-mode names.
- Verify all internal links.
- Verify Markdown anchors.
- Search for deprecated commands.
- Search for removed options.
- Search for obsolete paths.
- Search for stale network names.
- Search for stale secret names.
- Search for obsolete architecture assumptions.
- Search for language that incorrectly makes OCI mandatory.
- Search for references to behavior existing only in `main`.
- Verify both supported ingress deployment branches are accurately documented.
- Verify block storage appears in the README Quick Start.
- Verify block-storage instructions are non-destructive by default.
- Verify backup, restore, bootstrap recovery, and disaster recovery are
  consistent with one another.
- Regenerate command references through the supported process.
- Run Markdown lint where configured.
- Run link checking where configured.
- Review all changed documentation from the perspective of a junior
  administrator with no undocumented repository knowledge.

======================================================================
FINAL TESTING AND QUALITY GATE
======================================================================

After both steps, run the complete applicable validation suite.

At minimum, use all repository-provided checks plus applicable forms of:

- `bash -n` for Bash scripts.
- ShellCheck for shell scripts.
- shfmt check mode when configured.
- Existing unit tests.
- Existing integration tests.
- Newly added focused tests.
- Docker Compose configuration rendering.
- Validation for every supported Compose overlay or deployment mode.
- Command-help validation.
- Command-reference generation checks.
- Markdown lint.
- Link checking.
- Secret scanning.
- `git diff --check`.
- A review of executable permissions.
- A review for accidentally committed credentials or decrypted data.
- A repository-wide stale-identifier search.

Do not perform destructive testing against:

- A production host.
- A production volume.
- A real system disk.
- Production secrets.
- Production backup data.
- Production DNS.
- Production Cloudflare configuration.
- Production OCI resources.

Use:

- Temporary directories.
- Mocked commands.
- Test fixtures.
- Dry-run modes.
- Isolated containers.
- Disposable test resources where already supported.

When a validation cannot be run:

- State exactly which validation was not run.
- State the concrete environmental limitation.
- Perform the strongest safe substitute.
- Report the substitute.
- Do not claim the omitted validation passed.

A command being unavailable is not a reason to fabricate a result.

======================================================================
DIFF AND SCOPE REVIEW
======================================================================

Before committing:

1. Review the complete diff against `origin/Beta`.
2. Confirm every changed file is required by this assignment.
3. Confirm no unrelated cleanup was included.
4. Confirm no behavior was copied from `main` without justification.
5. Confirm public commands and flags remain compatible.
6. Confirm configuration keys remain compatible.
7. Confirm no version pins changed.
8. Confirm no security control was weakened.
9. Confirm no secret material was added.
10. Confirm generated files were produced through the supported process.
11. Confirm executable permissions are correct.
12. Confirm documentation matches the final code.
13. Confirm the README Quick Start contains block-storage instructions.
14. Confirm Step 2 began only after Step 1 passed its validation gate.

Use:

    git diff origin/Beta...HEAD
    git diff --check
    git status --short

or repository-equivalent commands.

======================================================================
COMMITS
======================================================================

Create logical commits.

Prefer at least:

1. `refactor: improve script portability and maintainability`
2. `docs: align operator documentation with Beta implementation`

Additional focused commits are acceptable when they make review clearer, such
as:

- `test: cover architecture and provider-neutral helpers`
- `docs: regenerate command reference`

Do not:

- Mix unrelated cleanup into the commits.
- Commit temporary files.
- Commit decrypted data.
- Commit local test artifacts.
- Amend unrelated pre-existing commits.
- force-push over another contributor’s work.
- squash unrelated changes together merely to reduce commit count.

Before pushing:

1. Fetch the latest `origin/Beta`.
2. Determine whether `Beta` advanced.
3. Rebase or otherwise update the working branch against `origin/Beta` using the
   repository’s accepted workflow.
4. Do not update against `main`.
5. Resolve conflicts by preserving `Beta` behavior.
6. Rerun all affected validation.
7. Confirm a clean working tree.
8. Confirm the merge base is current.

======================================================================
PULL REQUEST
======================================================================

Push the working branch and create a pull request with:

    Base branch: Beta
    Head branch: refactor/portable-scripts-and-docs

Use the actual head branch if it differs.

Suggested PR title:

    Improve script portability and refresh operator documentation

Before submitting the PR:

- Verify that the base branch shown by GitHub is `Beta`.
- Verify that the head branch is the dedicated working branch.
- Verify that the diff contains only intended changes.
- Do not submit the PR if GitHub shows `main` as the base.
- Do not rely only on the PR URL; inspect the branch metadata.

The pull-request body must contain the following sections.

## Summary

Provide a concise explanation of:

- Script portability improvements.
- Maintainability improvements.
- Cloud-neutral operation.
- Documentation synchronization.
- README Quick Start block-storage guidance.

## Scope

State that the PR is limited to:

- Script portability.
- Script maintainability.
- Comment quality.
- Focused validation and tests.
- Documentation synchronization.

State explicitly that unrelated features, dependency upgrades, version
upgrades, and architectural redesigns were excluded.

## Branch information

Include:

- Source base SHA from `origin/Beta`.
- PR base branch.
- PR head branch.
- Confirmation that the work was not based on `main`.

Use a format such as:

    Original base: origin/Beta at <commit-sha>
    PR base: Beta
    PR head: refactor/portable-scripts-and-docs
    Main used as source: No

## Script changes

Describe:

- CPU-architecture portability changes.
- Architecture-normalization behavior.
- Cloud-agnostic changes.
- Preserved optional OCI behavior.
- Dead-code removal.
- Redundancy removal.
- Shared-helper changes.
- Shell-safety improvements.
- Error-handling improvements.
- Comment cleanup.
- Operator-usability improvements.
- Public behavior deliberately preserved.

Do not claim a change that is not present in the diff.

## Documentation changes

Describe:

- Documentation areas updated.
- README Quick Start block-storage addition.
- Generic block-storage workflow.
- Optional OCI-specific guidance.
- Setup and deployment updates.
- Routine-operation updates.
- Maintenance updates.
- Backup updates.
- Restore updates.
- Disaster-recovery updates.
- Bootstrap-key recovery updates.
- Troubleshooting updates.
- Generated documentation refreshed.

## Preserved invariants

Explicitly confirm the final status of:

- Cloudflare-only deployment.
- Direct `acme_http` deployment.
- Docker Compose file-backed secrets.
- Existing network segmentation.
- `vaultwarden_egress`.
- Whether `caddy_external` exists and whether this PR changed it.
- Existing version pins.
- Existing build arguments.
- Existing setup workflow.
- Existing backup workflow.
- Existing restore workflow.
- Existing bootstrap recovery.
- Existing break-glass administration.
- Existing storage compatibility.

## Validation

List every validation command that was run and its result.

Group results where useful:

- Shell syntax.
- Static analysis.
- Formatting.
- Unit tests.
- Integration tests.
- Docker Compose rendering.
- Architecture tests.
- Provider-neutral tests.
- Documentation generation.
- Markdown validation.
- Link validation.
- Secret scanning.
- Diff validation.

Clearly identify:

- Passed checks.
- Pre-existing failures.
- Checks that could not be run.
- Substitute validation used.
- Environmental limitations.

Do not state “all tests pass” unless every applicable test actually passed.

## Checklist

Copy the complete mandatory working checklist into the PR body.

Ensure every applicable item is checked.

For non-applicable items, include the factual reason.

## Risks and limitations

Document:

- Residual compatibility risks.
- Architectures not validated.
- Cloud-provider behavior not integration-tested.
- Environmental limitations.
- Existing baseline failures.
- Manual validation still recommended.
- Any behavior intentionally left unchanged because changing it was outside
  scope.

## Out-of-scope observations

List unrelated issues found during the work.

Do not imply that those issues were fixed.

If there were no out-of-scope observations, state:

    None identified.

======================================================================
COMPLETION CONDITIONS
======================================================================

The assignment is complete only when all of the following are true:

- `origin/Beta` was verified before implementation.
- The working branch was created from the current `origin/Beta`.
- The work was not based on `main`.
- Step 1 was fully implemented.
- Step 1 passed its validation gate.
- Step 2 began only after the Step 1 gate was complete.
- Step 2 was fully implemented.
- All applicable checklist items are complete.
- Script behavior remains compatible with supported `Beta` workflows.
- Core operation is not unnecessarily coupled to OCI.
- Optional OCI behavior remains supported.
- Supported CPU architectures are handled deterministically.
- Unsupported architectures fail clearly.
- Security controls were not weakened.
- Documentation matches the final implementation.
- Documentation reflects `Beta`, not `main`.
- README Quick Start includes safe block-storage instructions.
- Setup and maintenance guidance is accurate.
- Backup guidance is accurate.
- Restore guidance is accurate.
- Disaster-recovery guidance is accurate.
- Bootstrap-key recovery guidance is accurate.
- Tests and validation were run and reported honestly.
- The working branch was synchronized with the latest `origin/Beta`.
- The working branch was pushed.
- A pull request was created.
- The pull request targets `Beta`.
- The pull request does not target `main`.
- The PR base and head metadata were inspected and confirmed.
- The PR contains the completed checklist.
- The PR contains validation evidence.
- The PR contains risks and limitations.
- The PR contains out-of-scope observations.

The agent’s final response must include:

- Pull-request URL.
- PR title.
- Base branch.
- Head branch.
- Original `origin/Beta` SHA.
- Final head SHA.
- Commit summary.
- Files-changed summary.
- Validation summary.
- Any pre-existing failures.
- Any checks that could not be run.
- Remaining risks or limitations.
- Confirmation that the PR base was inspected and is `Beta`.

Do not stop after producing an audit, recommendations, or a proposed diff.

Implement the changes, validate them, push the branch, and create the pull
request.

Do not expand the assignment beyond the defined scope.
