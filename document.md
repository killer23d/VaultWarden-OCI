You are continuing work started in a prior session.

This is Prompt 2 of 2.

Step 1 — script optimization — has already been completed and validated.

Use the Prompt 1 handoff below as authoritative context.

Before starting, paste or confirm the Prompt 1 handoff values:

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
- Pre-existing baseline failures:
- Validation commands run:
- Validation results:
- Checks that could not be run:
- Substitute validation used:
- Out-of-scope observations:
- Confirmation that Step 1 validation gate passed:

Do not re-run Step 1 work unless a documentation validation step reveals a
script/documentation mismatch caused by an error in the Step 1 implementation.

If a Step 1 defect is discovered:

1. Stop documentation editing.
2. Fix only the minimum script defect required.
3. Rerun the affected Step 1 validation.
4. Record the reason clearly in the final PR body.
5. Resume documentation work only after the Step 1 gate is restored.

======================================================================
PRIMARY OBJECTIVE
======================================================================

Update all relevant user-facing documentation to match the final implementation
on the existing working branch created from `Beta`.

Then run final validation and create a pull request targeting `Beta`.

The final pull request must include both:

1. The completed Step 1 script optimization work.
2. The completed Step 2 documentation update work.

The pull request must target:

    Base branch: Beta

Do not target `main`.

======================================================================
BRANCH SAFETY
======================================================================

Use the existing working branch from Prompt 1.

Do not create a new unrelated branch unless the Prompt 1 branch is unavailable
or unsafe to use.

Before editing documentation:

1. Fetch all current remote references.
2. Verify that `origin/Beta` exists.
3. Verify that the current working branch is the Prompt 1 working branch.
4. Verify that the working branch contains the Prompt 1 head SHA or its
   descendants.
5. Verify that the working branch is based on `origin/Beta`, not `main`.
6. Record the current `origin/Beta` SHA.
7. Determine whether `origin/Beta` advanced since Prompt 1.
8. If needed, update the working branch against `origin/Beta`.
9. Do not update against `main`.
10. Rerun affected validation after any synchronization.

Do not:

- Recreate the Prompt 1 work from scratch.
- Base the work on `main`.
- Merge `main` into the working branch.
- Rebase the working branch onto `main`.
- Copy documentation from `main` as the source of truth.
- Create the final pull request against `main`.

If `origin/Beta` does not exist:

- Do not silently fall back to `main`.
- Stop implementation.
- Report the available remote branches and the exact branch-name problem.

If `Beta` differs from `main`, preserve the implementation, behavior,
architecture, documentation style, and documentation structure of `Beta`.

Before completing the assignment, inspect the final pull request metadata and
explicitly confirm:

    Base: Beta
    Head: <working-branch>

======================================================================
STRICT SCOPE CONTROL
======================================================================

Stay on task.

Permitted changes in Prompt 2:

- README files.
- Markdown files under `docs/`.
- Other user-facing documentation.
- Script help text only if documentation validation proves it is inaccurate
  after Step 1.
- Documentation generators and their sources.
- Generated command references, but only through the repository’s supported
  generation process.
- Examples and sample configuration that must be synchronized with the final
  implementation.
- Minimal script fixes only if required to correct a Prompt 1 defect discovered
  during documentation validation.

Not permitted unless strictly required to complete this assignment:

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
- Repository-wide formatting unrelated to modified files.
- Fixing unrelated issues found during documentation review.

When an unrelated issue is discovered:

1. Do not fix it.
2. Record it under the PR body section `Out-of-scope observations`.
3. Continue only with assigned documentation and PR work.

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
MANDATORY INVARIANTS TO PRESERVE
======================================================================

Do not re-audit all script behavior unless needed for documentation accuracy.

However, documentation must accurately preserve and describe the current final
working-branch behavior for:

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
- Existing version pins and build-argument wiring.

Do not document a `caddy_external` network unless it exists in the current final
working branch.

Do not update version pins as part of Prompt 2.

Do not weaken or inaccurately document:

- Secret isolation.
- File permissions.
- Container hardening.
- Network isolation.
- Firewall controls.
- Backup validation.
- Restore safeguards.
- Destructive-operation confirmations.
- Data-integrity checks.

======================================================================
PROMPT 2 CHECKLIST
======================================================================

Create and maintain this checklist in the agent’s working plan.

Do not add a temporary checklist file to the repository unless the repository
already has an established convention requiring one.

Copy the final completed checklist into the pull-request description.

[P2-A] Handoff and branch verification
- [ ] Read the Prompt 1 handoff.
- [ ] Confirm Step 1 validation gate passed.
- [ ] Confirm Step 2 has not already been completed.
- [ ] Fetch all remote references.
- [ ] Verify that `origin/Beta` exists.
- [ ] Verify the existing working branch.
- [ ] Verify the working branch contains the Prompt 1 head SHA or its
      descendants.
- [ ] Confirm the working branch is not based on `main`.
- [ ] Record the current `origin/Beta` SHA.
- [ ] Determine whether `origin/Beta` advanced since Prompt 1.
- [ ] Synchronize with `origin/Beta` if required.
- [ ] Rerun affected validation after synchronization.

[P2-B] Documentation update
- [ ] Begin documentation edits only after Step 1 is confirmed complete and
      validated.
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

[P2-C] Final validation and pull request
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
- [ ] Create logical documentation/final commits.
- [ ] Push the dedicated working branch.
- [ ] Create the pull request with `Beta` as the base branch.
- [ ] Inspect and confirm the PR’s base and head branches.
- [ ] Include the completed Prompt 1 checklist or handoff summary in the PR
      body.
- [ ] Include the completed Prompt 2 checklist in the PR body.
- [ ] Include validation evidence in the PR body.
- [ ] Include risks, limitations, and out-of-scope observations.
- [ ] Return the pull-request URL.

If a checklist item is not applicable, mark it explicitly as:

    [x] Not applicable — <brief factual reason>

Do not silently omit checklist items.

======================================================================
STEP 2 — DOCUMENTATION UPDATE
======================================================================

Begin Step 2 only after confirming that Step 1 has been implemented, reviewed,
and validated.

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
supported by the current final working-branch implementation.

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

After documentation work, run the complete applicable validation suite.

At minimum, use all repository-provided checks plus applicable forms of:

- `bash -n` for Bash scripts.
- ShellCheck for shell scripts.
- shfmt check mode when configured.
- Existing unit tests.
- Existing integration tests.
- Newly added focused tests from Prompt 1.
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

Before committing and before opening the PR:

1. Review the complete diff against `origin/Beta`.
2. Confirm every changed file is required by this two-prompt assignment.
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

Create logical commits for Prompt 2 work.

Suggested commit messages:

    docs: align operator documentation with Beta implementation
    docs: refresh generated command reference

If a minimal script correction was required after discovering a Prompt 1 defect,
use a separate focused commit such as:

    fix: correct script behavior found during documentation validation

Do not:

- Mix unrelated cleanup into the commits.
- Commit temporary files.
- Commit decrypted data.
- Commit local test artifacts.
- Amend unrelated pre-existing commits.
- Force-push over another contributor’s work.
- Squash unrelated changes together merely to reduce commit count.

Before pushing:

1. Fetch the latest `origin/Beta`.
2. Determine whether `Beta` advanced.
3. Rebase or otherwise update the working branch against `origin/Beta` using
   the repository’s accepted workflow.
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
    Head branch: <working-branch>

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

    Original base: origin/Beta at <commit-sha>
    Final synchronized base: origin/Beta at <commit-sha>
    PR base: Beta
    PR head: <working-branch>
    Main used as source: No

## Script changes

Summarize Prompt 1 work:

- CPU-architecture portability changes.
- Architecture handling approach.
- Cloud-agnostic changes.
- Preserved optional OCI behavior.
- Dead-code removal.
- Redundancy removal.
- Shared-helper changes, if any.
- Shell-safety improvements.
- Error-handling improvements.
- Comment cleanup.
- Operator-usability improvements.
- Public behavior deliberately preserved.

Do not claim a change that is not present in the diff.

## Documentation changes

Describe Prompt 2 work:

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
- Architecture handling tests.
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

## Prompt 1 handoff summary

Include:

- Prompt 1 working branch.
- Prompt 1 base SHA.
- Prompt 1 head SHA.
- Prompt 1 validation summary.
- Prompt 1 pre-existing baseline failures.
- Confirmation that Prompt 1 Step 1 validation gate passed before Prompt 2
  documentation work began.

## Checklists

Include:

- Completed Prompt 1 checklist or a faithful completed summary from the Prompt
  1 handoff.
- Completed Prompt 2 checklist.

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

List unrelated issues found during Prompt 1 or Prompt 2.

Do not imply that those issues were fixed.

If there were no out-of-scope observations, state:

    None identified.

======================================================================
COMPLETION CONDITIONS
======================================================================

The full two-prompt assignment is complete only when all of the following are
true:

- Prompt 1 handoff was reviewed.
- Step 1 validation gate was confirmed complete.
- The existing working branch from Prompt 1 was used.
- `origin/Beta` was verified before Prompt 2 documentation work.
- The work was not based on `main`.
- Step 2 began only after the Step 1 gate was complete.
- Step 2 was fully implemented.
- All applicable Prompt 2 checklist items are complete.
- Script behavior remains compatible with supported `Beta` workflows.
- Core operation is not unnecessarily coupled to OCI.
- Optional OCI behavior remains supported.
- Architecture handling remains minimal, deterministic, and tested where
  applicable.
- Unsupported architectures fail clearly where architecture-specific handling
  exists.
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
- The PR contains Prompt 1 handoff information.
- The PR contains the completed Prompt 2 checklist.
- The PR contains validation evidence.
- The PR contains risks and limitations.
- The PR contains out-of-scope observations.

The agent’s final response must include:

- Pull-request URL.
- PR title.
- Base branch.
- Head branch.
- Original `origin/Beta` SHA from Prompt 1.
- Final synchronized `origin/Beta` SHA.
- Final head SHA.
- Commit summary.
- Files-changed summary.
- Validation summary.
- Any pre-existing failures.
- Any checks that could not be run.
- Remaining risks or limitations.
- Confirmation that the PR base was inspected and is `Beta`.

Do not stop after producing an audit, recommendations, or a proposed diff.

Finish the documentation work, validate it, push the branch, and create the pull
request.

Do not expand the assignment beyond the defined scope.
