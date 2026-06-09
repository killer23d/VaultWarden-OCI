You are continuing an existing comment-pruning task in:

Repository: killer23d/VaultWarden-OCI
Existing pull request: PR #171
PR URL: https://github.com/killer23d/VaultWarden-OCI/pull/171
PR base branch: Beta
Existing working branch: chore/prune-lib-comments
Expected starting head SHA: 2e0602087373ec423640b434e60baa061e596efd

The `lib/` directory has already been reviewed and committed.

Your assignment is to continue the same comment-pruning policy across the
remaining applicable source and configuration files in the repository, commit
the results to the existing `chore/prune-lib-comments` branch, push the branch,
and update PR #171.

Do not create a new branch.

Do not create a new pull request.

======================================================================
OBJECTIVE
======================================================================

Review comments in applicable repository files outside `lib/`.

Prune unnecessary, narrative, redundant, stale, and
implementation-explanation comments while preserving comments that serve an
important:

- File or module identification purpose.
- Navigation purpose.
- Interface or usage-contract purpose.
- Administrator-configuration purpose.
- Safety purpose.
- False-positive prevention purpose.
- Tool or interpreter requirement.

Preserve all useful runtime logging and operator-visible output.

This is a comment-maintenance task only.

Do not refactor code, change behavior, update user documentation, upgrade
dependencies, or fix unrelated issues.

======================================================================
CONTINUATION AND BRANCH SAFETY
======================================================================

Before changing files:

1. Fetch all current remote references.
2. Verify that PR #171 is still open.
3. Verify that the PR base is `Beta`.
4. Verify that the PR head is `chore/prune-lib-comments`.
5. Check out the existing local or remote branch:

       chore/prune-lib-comments

6. Verify that the branch contains commit:

       2e0602087373ec423640b434e60baa061e596efd

   or a descendant of that commit.

7. Verify that the existing `lib/` comment-pruning changes are present.
8. Record the current `origin/Beta` SHA.
9. Determine whether `origin/Beta` advanced after PR #171 was created.
10. Do not merge or rebase onto `main`.

If the expected branch or prior commit is missing:

- Do not recreate the work from `main`.
- Do not create a replacement PR.
- Stop and report the discrepancy.

If `origin/Beta` advanced, synchronize the existing branch using the
repository’s accepted workflow before final validation. Preserve the existing
PR #171 changes.

======================================================================
SCOPE
======================================================================

The previously completed `lib/` files are out of scope for additional editing
unless a clearly accidental inconsistency in the prior comment-only work must
be corrected.

Review applicable files outside `lib/`, including:

- Top-level `*.sh` scripts.
- Shell scripts in subdirectories other than `lib/`.
- Fail2ban shell helpers.
- CrowdSec shell helpers.
- Firewall and networking shell scripts.
- Backup, restore, setup, startup, maintenance, uninstall, secret-management,
  and administration scripts.
- Test shell scripts.
- Shell-based tooling and generators.
- Dockerfiles or Containerfiles where comments describe build implementation.
- Docker Compose YAML files and examples where comments provide operator
  guidance or narrate configuration.
- Environment examples where comments instruct administrators.
- Service, timer, Fail2ban, CrowdSec, or other configuration templates where
  comments serve a real configuration or safety purpose.
- Makefiles where comments are source comments rather than command output.

First inventory the repository and identify every applicable non-`lib/` file
that contains comments.

Do not assume that every file type should be edited. Apply the comment policy
according to the role of each file.

======================================================================
FILES AND CONTENT OUT OF SCOPE
======================================================================

Do not edit user documentation as part of this task, including:

- `README.md`
- Files under `docs/`
- Other user manuals or narrative Markdown documentation
- Changelogs
- Release notes

Do not edit:

- Vendored or third-party files.
- Generated files unless their authoritative source is also in scope and the
  repository requires regeneration.
- Lock files.
- Binary files.
- Data fixtures whose `#` characters are data rather than comments.
- Encrypted files.
- Secret material.
- Backup data.
- Files outside the repository.

Do not change heredoc contents merely because lines inside the heredoc begin
with `#`.

Treat heredoc content according to what it generates:

- If it generates runtime configuration, comments inside it may be
  administrator-facing configuration guidance and may need to remain.
- If it generates a script, apply the normal shell-comment policy carefully.
- If it contains literal data, do not treat `#` lines as source comments.
- Do not modify heredoc payloads unless comment pruning within that generated
  content is clearly in scope and behavior can be proven unchanged.

======================================================================
PERMITTED CHANGES
======================================================================

Permitted:

- Delete unnecessary source comments.
- Shorten or rewrite retained comments.
- Correct inaccurate comments.
- Preserve or correct top-of-file headers.
- Preserve or correct structured interface headers.
- Preserve meaningful phase and section headings.
- Remove blank lines left behind by deleted comments.
- Make minimal whitespace changes directly caused by comment pruning.
- Update the title and body of PR #171 to reflect the expanded repository scope.
- Add a focused comment-only commit to the existing PR branch.

Not permitted:

- Functional code changes.
- Refactoring.
- Function renaming.
- Variable renaming.
- Moving or reordering functions.
- Reordering commands.
- Changing conditions or control flow.
- Changing exit codes.
- Changing traps.
- Changing source/load order.
- Changing paths.
- Changing permissions.
- Changing configuration values.
- Changing defaults.
- Changing service behavior.
- Changing network behavior.
- Changing container behavior.
- Changing environment-variable semantics.
- Changing command-line interfaces.
- Changing dependencies or versions.
- Removing dead code.
- Adding helpers.
- Reformatting unrelated executable code.
- Updating user documentation.
- Creating another PR.

The final new diff for this continuation must be comment-only apart from
directly resulting whitespace.

======================================================================
SHEBANGS, FILE HEADERS, AND MODULE HEADERS
======================================================================

A shebang is the interpreter directive, for example:

    #!/usr/bin/env bash

Preserve all shebangs.

For executable scripts, preserve a concise top-of-file script header such as:

    #!/usr/bin/env bash
    # setup.sh — Install and configure VaultWarden-OCI.

A script header should normally contain:

- The file name.
- A brief description of its operator-visible purpose.

Do not expand an executable script header into a detailed implementation
walkthrough.

Preserve structured file or module headers when they provide a meaningful
interface or usage reference.

A structured header may include:

- File name and purpose.
- Public commands or functions.
- Required inputs.
- Exported variables.
- Dependencies.
- Required load order.
- Initialization requirements.
- Canonical invocation or source examples.
- Important usage constraints applying to the whole file.

Keep these headers accurate, but do not turn them into tutorials or internal
control-flow descriptions.

======================================================================
COMMENT RETENTION POLICY
======================================================================

Comment deletion is the default.

A comment may remain only when it belongs to one of the approved categories
below.

----------------------------------------------------------------------
1. FILE OR MODULE HEADER
----------------------------------------------------------------------

Retain:

- Shebangs.
- Concise executable-script headers.
- Structured module or interface headers.
- License and copyright headers.
- Required attribution notices.

Remove top-of-file prose that:

- Narrates implementation steps.
- Describes execution order in detail.
- Duplicates user documentation.
- Contains historical context.
- Describes future plans.
- Is no longer accurate.

----------------------------------------------------------------------
2. PHASE AND SECTION HEADINGS
----------------------------------------------------------------------

Retain concise headings that help an administrator or maintainer navigate a
long file.

Examples:

    # Phase 1: Validate prerequisites
    # Storage preparation
    # Backup verification
    # Firewall rules
    # Public commands

Retain a heading only when it groups a meaningful block of related logic.

Remove headings that:

- Precede a single trivial command.
- Repeat the following function name.
- Divide code into unnecessarily small sections.
- Exist only for decoration.
- No longer match the code below them.

----------------------------------------------------------------------
3. FUNCTION OR INTERFACE CONTRACT
----------------------------------------------------------------------

Retain a concise comment when it documents:

- A non-obvious public input.
- A non-obvious output or return status.
- A caller-visible side effect.
- A required precondition.
- A meaningful distinction between similar public functions.
- A calling convention not evident from the function signature.

Remove comments that merely restate a function name.

For example, remove:

    # Check whether Docker is running.
    is_docker_running() {
        ...
    }

Retain only information that a caller cannot immediately infer.

----------------------------------------------------------------------
4. ADMINISTRATOR CONFIGURATION
----------------------------------------------------------------------

Retain comments that tell an administrator:

- Which value must be supplied.
- Which setting must be changed.
- Which path must be configured.
- Which identifier must be obtained externally.
- Which option is required or optional.
- Which environment variable controls behavior.
- Which value must remain unchanged.
- Which configuration block may be customized.
- Which deployment choice the operator must make.

Configuration examples such as `.env.example`, Compose examples, service
templates, and security-tool configuration may legitimately contain more
administrator guidance than executable shell scripts.

Do not remove useful configuration guidance merely to reduce comment count.

Do not classify implementation narration as administrator configuration.

----------------------------------------------------------------------
5. SAFETY WARNING
----------------------------------------------------------------------

Retain concise warnings immediately before:

- Destructive filesystem operations.
- Storage formatting or repartitioning.
- Backup deletion.
- Restore operations that overwrite data.
- Secret deletion or replacement.
- Privileged changes.
- Firewall resets.
- Actions that may cause service interruption.
- Irreversible operations.
- Security-sensitive actions where misuse creates a realistic risk.

A safety comment must identify the actual risk.

Remove vague warnings that do not help prevent a specific unsafe action.

----------------------------------------------------------------------
6. FALSE-POSITIVE PREVENTION
----------------------------------------------------------------------

Retain a brief comment only when intentional code is realistically likely to
be incorrectly flagged by:

- A code reviewer.
- A security reviewer.
- A linter.
- Static analysis.
- A future maintainer removing apparently redundant code.

The comment must explain:

1. The specific apparent problem.
2. Why the code is intentionally required or safe.

Examples that may qualify:

- An intentionally ignored failure.
- A required security exception.
- A command that appears redundant but prevents a known data-loss or race
  condition.
- A ShellCheck suppression requiring justification.
- Unusual quoting required by an external interface.
- A deliberately broad or narrow permission that would otherwise appear
  incorrect.

The following do not automatically qualify:

- Non-obvious implementation details.
- Routine package-manager behavior.
- Routine package `postinst` behavior.
- Normal shell behavior.
- Phase-to-phase dependencies.
- Temporary intermediate files.
- Compatibility workarounds.
- Execution ordering.
- An unusual command.
- Code that merely benefits from explanation.

Retain a false-positive comment only when removing it creates a realistic risk
that required code will be flagged or removed incorrectly.

Keep it concise.

----------------------------------------------------------------------
7. REQUIRED DIRECTIVES
----------------------------------------------------------------------

Preserve comments required by tools or interpreters, including:

- ShellCheck directives.
- Linter suppression directives.
- Build directives.
- Syntax directives.
- Required template markers.
- Required generated-file markers.

Where a suppression directive requires justification, retain the shortest
accurate explanation needed.

Do not remove or alter required machine-readable markers.

======================================================================
COMMENTS TO REMOVE
======================================================================

Remove comments that:

- Narrate the next command.
- Restate what the code visibly does.
- Explain normal control flow.
- Explain obvious `if`, `case`, loop, assignment, or return behavior.
- Explain that one phase prepares data for a later phase.
- Describe temporary variables.
- Describe temporary files.
- Explain routine package-manager behavior.
- Explain routine package `postinst` behavior.
- Explain routine command behavior.
- Explain why a file is created, copied, moved, or deleted when the purpose is
  evident from the operation or surrounding structure.
- Describe internal implementation details irrelevant to an administrator,
  caller, or reviewer.
- Repeat a nearby runtime log.
- Repeat a function name.
- Repeat a variable name.
- Repeat a condition.
- Repeat information already present in user documentation.
- Contain historical context.
- Describe previous implementations.
- Contain stale TODO items.
- Contain speculative future work.
- Are conversational.
- Are tutorial-like.
- Are excessively verbose.
- Explain obvious syntax.
- Add no interface, navigation, configuration, safety, directive, or
  false-positive value.

Comments such as this should normally be removed:

    # Pre-create a minimal stub config so the package postinst script does
    # not abort trying to open a non-existent config file. Phase 6 overwrites.

Do not retain such comments merely because they explain why an implementation
step exists.

Do not replace removed comments with new runtime logging.

Do not change code merely to make a comment removable.

======================================================================
RUNTIME LOGGING AND OPERATOR OUTPUT
======================================================================

Runtime logging is executable behavior, not comment content.

Do not remove, rewrite, suppress, relocate, or combine:

- `log_info`
- `log_warn`
- `log_error`
- `log_debug`
- Progress messages
- Status messages
- Prompts
- Runtime `printf`
- Runtime `echo`
- Help text
- Usage output
- Other operator-visible messages

Preserve runtime messages that:

- Show the current setup, maintenance, backup, restore, or recovery phase.
- State what meaningful operation is underway.
- Report completion of a meaningful step.
- Explain a failure.
- State the next corrective action.
- Warn before destructive actions.
- Provide useful diagnostic context.
- Confirm selected paths, modes, services, or resources without exposing
  sensitive information.

A nearby comment may be redundant because a runtime log already provides
sufficient context. Remove the comment, not the log.

Do not replace deleted comments with verbose runtime narration.

Runtime logging must be excluded from comment-removal metrics.

======================================================================
INLINE COMMENTS
======================================================================

Review inline comments separately.

Retain an inline comment only when it communicates:

- A required configuration choice.
- A safety constraint.
- A non-obvious public contract.
- A narrow false-positive justification.
- A required tool directive.

Remove inline comments that:

- Restate the assignment.
- Repeat the variable name.
- Explain obvious syntax.
- Duplicate a surrounding header.
- Duplicate help or documentation.
- Narrate a command argument already clear from context.

Do not reformat executable code unnecessarily when removing inline comments.

======================================================================
CONFIGURATION-FILE COMMENTS
======================================================================

Configuration files and examples require different judgment from executable
scripts.

Preserve comments that help an administrator safely configure:

- Environment variables.
- Paths.
- Ports.
- Domains.
- Credentials references.
- Secret file locations.
- Storage locations.
- Optional services.
- Deployment modes.
- Network settings.
- Firewall settings.
- Backup and restore settings.
- Provider-specific optional values.

Remove comments that:

- Narrate parser behavior.
- Explain obvious YAML, INI, environment, or service syntax.
- Repeat the key name without adding guidance.
- Contain stale implementation detail.
- Duplicate a nearby, clearer comment.
- Describe internal code execution rather than operator configuration.

Do not change any configuration value, example value, ordering dependency, or
machine-readable structure.

======================================================================
DOCKERFILE AND COMPOSE COMMENTS
======================================================================

For Dockerfiles, Containerfiles, and Compose YAML:

Retain:

- Meaningful build-stage headings.
- Security-sensitive explanations.
- Administrator configuration guidance.
- Required compatibility warnings.
- Comments explaining a non-obvious constraint that would otherwise be
  realistically flagged or broken.
- Required syntax or tooling directives.

Remove:

- Comments that narrate each `RUN`, `COPY`, `ENV`, service, volume, or network.
- Comments that repeat service names.
- Comments that describe obvious image-building operations.
- Stale architecture or implementation notes.
- Comments duplicated by surrounding variable names or service structure.

Do not change:

- Build stages.
- Commands.
- Build arguments.
- Environment values.
- Image references.
- Volumes.
- Networks.
- Secrets.
- Health checks.
- Dependencies.
- Service ordering.

======================================================================
BLANK LINES AND VISUAL STRUCTURE
======================================================================

After pruning:

- Remove excess blank lines left behind.
- Preserve clear separation between functions and major sections.
- Preserve readable spacing in configuration examples.
- Do not collapse files into dense blocks.
- Do not perform unrelated formatting.
- Do not reorder comments merely for style.
- Do not reindent or reflow executable code unless directly required by comment
  removal.

======================================================================
CLASSIFICATION OF RETAINED COMMENTS
======================================================================

Internally classify each retained comment or block as one of:

- FILE-HEADER
- MODULE-HEADER
- SECTION-HEADING
- FUNCTION-CONTRACT
- ADMIN-CONFIG
- SAFETY-WARNING
- FALSE-POSITIVE
- REQUIRED-DIRECTIVE
- LICENSE

Shebangs are tracked separately.

If a comment cannot be classified into one of these categories, remove it.

Do not add these classification labels to source files.

Runtime logging and executable output are not comments and must not be included
in this classification.

======================================================================
VALIDATION
======================================================================

This task must not intentionally change executable or configuration behavior.

Run applicable validation for every changed file type.

At minimum:

1. Syntax-check all non-`lib/` shell scripts:

       find . -type f -name '*.sh' \
         -not -path './lib/*' \
         -not -path './.git/*' \
         -print0 |
         xargs -0 -n1 bash -n

2. Run the repository’s established ShellCheck command.

3. Run existing tests relevant to changed scripts and configuration.

4. Run repository lint targets applicable to changed files.

5. Validate Docker Compose files or examples using the repository-supported
   method without requiring production secrets or generated local state.

6. Validate applicable configuration syntax where tooling exists.

7. Run:

       git diff --check
       git status --short

8. Review the continuation diff separately from the existing `lib/` commit.

9. Compare changed files against the pre-continuation head SHA:

       2e0602087373ec423640b434e60baa061e596efd

10. Perform a non-comment behavior comparison for changed executable files.

Use an appropriate parser or normalization process to confirm executable shell
content is unchanged apart from whitespace caused by comment removal.

For shell comparisons, account carefully for:

- Shebangs.
- Standalone comments.
- Inline comments.
- Quoted `#` characters.
- Parameter expansions containing `#`.
- Heredoc payloads.
- Blank lines.

Do not use a naïve comment-stripping command that mistakes quoted or generated
content for comments.

Manually review any detected executable difference.

Confirm:

- No function behavior changed.
- No function name changed.
- No variable changed.
- No command changed.
- No argument changed.
- No condition changed.
- No command order changed.
- No source/load order changed.
- No runtime logging changed.
- No prompt changed.
- No help text changed.
- No heredoc payload unintentionally changed.
- No configuration value changed.
- No service, network, volume, secret, or dependency changed.
- No user-documentation file changed.
- The existing `lib/` commit remains intact.

Record pre-existing failures separately.

Do not claim a check passed if it was not run.

======================================================================
AUDIT METRICS
======================================================================

Report continuation metrics separately from the existing `lib/` metrics.

Continuation metrics:

- Number of applicable non-`lib/` files reviewed.
- Number of non-`lib/` files changed.
- Files reviewed by type.
- Files changed by type.
- Standalone comments removed.
- Inline comments removed.
- Comments rewritten.
- Script/file headers retained.
- Structured module headers retained.
- Section headings retained.
- Function-contract comments retained.
- Administrator-configuration comments retained.
- Safety-warning comments retained.
- False-positive comments retained.
- Required directives retained.
- License notices retained.
- Confirmation that runtime logging was excluded from metrics.
- Confirmation that no runtime logging was removed or rewritten.

Also preserve the existing PR 171 `lib/` metrics and add a combined summary:

Existing `lib/` metrics from PR #171:

- `lib/` files reviewed: 14
- `lib/` files changed: 13
- Standalone comments removed: 114
- Inline comments removed: 6
- Comments rewritten: 0
- Structured library headers retained: 14
- Structured library headers corrected: 0
- Section heading comment blocks retained: 84
- Function-contract comment blocks retained: 85
- Administrator-configuration comment blocks retained: 51
- Safety-warning comment blocks retained: 52
- False-positive comments retained: 0 outside required directives
- Required directives retained: 23
- Runtime logging removed or rewritten: no

Do not overwrite these prior metrics with the continuation metrics.

For every newly retained FALSE-POSITIVE comment, report:

- File path.
- Line or function context.
- Reason it remains necessary.

======================================================================
CHECKLIST
======================================================================

Maintain this checklist during the continuation.

Continuation and branch
- [ ] Fetch remote references.
- [ ] Verify PR #171 is open.
- [ ] Verify PR #171 base is `Beta`.
- [ ] Verify PR #171 head is `chore/prune-lib-comments`.
- [ ] Check out the existing branch.
- [ ] Verify the branch contains the prior head SHA or a descendant.
- [ ] Verify existing `lib/` changes are intact.
- [ ] Record the current `origin/Beta` SHA.
- [ ] Determine whether `origin/Beta` advanced.
- [ ] Confirm no work is based on `main`.

Inventory and scope
- [ ] Inventory applicable non-`lib/` files containing comments.
- [ ] Exclude user documentation.
- [ ] Exclude third-party and generated files unless explicitly applicable.
- [ ] Identify heredoc and generated-content risks.
- [ ] Confirm the planned file list before editing.
- [ ] Confirm no additional `lib/` work is planned.

Comment review
- [ ] Review every applicable file header.
- [ ] Review structured module headers.
- [ ] Review phase and section headings.
- [ ] Review function-level comments.
- [ ] Review inline comments.
- [ ] Review configuration guidance.
- [ ] Review Dockerfile and Compose comments.
- [ ] Review required directives.
- [ ] Remove narrative comments.
- [ ] Remove implementation-explanation comments.
- [ ] Remove comments duplicated by runtime logging.
- [ ] Remove stale comments.
- [ ] Preserve administrator configuration guidance.
- [ ] Preserve safety warnings.
- [ ] Preserve narrow false-positive comments.
- [ ] Preserve shebangs.
- [ ] Preserve license notices.
- [ ] Preserve runtime logging.
- [ ] Remove excess blank lines caused by pruning.

Validation
- [ ] Confirm the continuation diff is comment-only.
- [ ] Confirm executable behavior is unchanged.
- [ ] Confirm configuration behavior is unchanged.
- [ ] Run `bash -n` on applicable shell scripts.
- [ ] Run ShellCheck.
- [ ] Run relevant tests.
- [ ] Run applicable lint targets.
- [ ] Validate applicable Compose/configuration files.
- [ ] Run `git diff --check`.
- [ ] Confirm no runtime log changed.
- [ ] Confirm no prompt or help output changed.
- [ ] Confirm no heredoc payload unintentionally changed.
- [ ] Confirm no user-documentation file changed.
- [ ] Confirm existing `lib/` changes remain intact.
- [ ] Record pre-existing failures separately.
- [ ] Complete continuation metrics.
- [ ] Prepare combined PR metrics.

Commit and PR update
- [ ] Create a focused continuation commit.
- [ ] Fetch the latest `origin/Beta`.
- [ ] Synchronize with `origin/Beta` if required.
- [ ] Rerun affected validation after synchronization.
- [ ] Push `chore/prune-lib-comments`.
- [ ] Confirm PR #171 updated with the new commit.
- [ ] Update the PR title if needed.
- [ ] Update the PR summary and scope.
- [ ] Add continuation metrics.
- [ ] Preserve prior `lib/` metrics.
- [ ] Add combined metrics.
- [ ] Update validation results.
- [ ] Add newly retained false-positive justifications.
- [ ] Update out-of-scope observations.
- [ ] Verify PR base remains `Beta`.
- [ ] Verify PR head remains `chore/prune-lib-comments`.

For a non-applicable item, use:

    [x] Not applicable — <specific reason>

Do not silently omit checklist items.

======================================================================
COMMIT
======================================================================

Add a new focused commit to the existing branch.

Suggested commit message:

    chore: prune narrative comments from remaining source files

An acceptable alternative is:

    chore: extend comment pruning across repository scripts

Do not amend or replace the existing `lib/` commit unless necessary to correct
a clear mistake.

Do not squash the prior commit unless explicitly required by repository policy.

Push the new commit to:

    chore/prune-lib-comments

======================================================================
UPDATE PR #171
======================================================================

Do not create another pull request.

Update PR #171 to describe the expanded scope.

Suggested updated title:

    Prune narrative comments across repository scripts

The PR body must retain the prior `lib/` results and add the continuation work.

Use these sections:

## Summary

State that the PR now:

- Prunes unnecessary comments from `lib/`.
- Extends the same policy to applicable source and configuration files outside
  `lib/`.
- Preserves structured headers.
- Preserves meaningful navigation headings.
- Preserves administrator configuration guidance.
- Preserves safety warnings.
- Preserves narrowly justified false-positive comments.
- Preserves runtime logging.
- Does not intentionally change executable or configuration behavior.

## Scope

State:

- `lib/` was reviewed in the first commit.
- Remaining applicable source and configuration files were reviewed in the
  continuation commit.
- User documentation was not updated.
- Runtime output was not changed.
- Dependencies and versions were not changed.
- No functional refactoring was performed.

List the file types included and excluded.

## Comment policy

Summarize the approved retained categories:

- File and module headers.
- Section headings.
- Function contracts.
- Administrator configuration.
- Safety warnings.
- False-positive prevention.
- Required directives.
- License notices.

State that narrative and implementation-explanation comments were removed by
default.

## First-pass `lib/` metrics

Preserve the existing metrics exactly unless a prior metric was demonstrably
incorrect.

## Continuation metrics

Add all newly required metrics for files outside `lib/`.

## Combined metrics

Provide aggregate totals across both commits where the categories are
compatible.

Do not combine unlike measurements misleadingly.

## Retained false-positive comments

List retained false-positive comments from both passes.

If none exist outside required directives, state that clearly.

## Validation

Separate:

- Initial `lib/` validation.
- Continuation validation.
- Final full-branch validation.
- Pre-existing or environment-limited failures.

Preserve the existing note that `make test-config` failed because no generated
`docker-compose.yml` was present, unless the current branch state or validation
method has changed.

Do not claim that this pre-existing/environment-limited check passed.

## Runtime logging

Confirm:

- Runtime logging was treated as executable behavior.
- No useful log, prompt, progress, status, help, or usage message was removed.
- Runtime logging was excluded from comment metrics.
- No runtime logging was rewritten.

## Out-of-scope observations

List issues found but not changed.

## Checklist

Include the completed continuation checklist.

The existing first-pass checklist may remain or be condensed into a clearly
labeled completed first-pass section. Do not erase evidence of the initial
`lib/` review.

======================================================================
COMPLETION CONDITIONS
======================================================================

The continuation is complete only when:

- PR #171 remains open.
- The existing branch was reused.
- The prior `lib/` commit remains present.
- Every applicable non-`lib/` source/configuration file was reviewed.
- User documentation was not changed.
- Narrative comments were removed by default.
- Implementation-explanation comments were removed by default.
- Structured headers were preserved.
- Administrator configuration guidance was preserved.
- Safety warnings were preserved.
- Runtime logging was preserved.
- No executable behavior intentionally changed.
- No configuration behavior intentionally changed.
- Validation was completed or limitations were reported honestly.
- A new focused commit was pushed to `chore/prune-lib-comments`.
- PR #171 contains the new commit.
- PR #171’s title and body reflect the expanded scope.
- PR #171 still targets `Beta`.
- PR #171 still uses `chore/prune-lib-comments` as its head.
- The PR includes separate and combined audit metrics.
- The PR includes validation results.
- The PR includes false-positive justifications.
- The PR includes out-of-scope observations.

The final response must include:

- PR URL.
- Updated PR title.
- Base branch.
- Head branch.
- Starting head SHA.
- New final head SHA.
- New commit SHA and message.
- Current `origin/Beta` SHA.
- Files reviewed.
- Files changed.
- Continuation comment metrics.
- Combined comment metrics.
- Validation summary.
- Pre-existing failures.
- Checks that could not be run.
- Remaining limitations.
- Confirmation that no new PR was created.
- Confirmation that PR #171 remains based on `Beta`.

Do not stop after auditing or proposing changes.

Complete the pruning, validate it, commit it to the existing branch, push it,
and update PR #171.
