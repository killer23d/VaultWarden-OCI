You are working in the following repository:

Repository: killer23d/VaultWarden-OCI
Target base branch: Beta

Your assignment is limited to pruning and improving source comments in the
`lib/` directory.

After completing and validating the work, create a new pull request targeting
the `Beta` branch.

======================================================================
OBJECTIVE
======================================================================

Review every shell source file under:

    lib/

Prune unnecessary, narrative, redundant, stale, or implementation-explanation
comments while preserving comments that serve an important navigation,
interface, configuration, safety, or review purpose.

This task is comment maintenance only.

Do not refactor behavior, redesign functions, optimize scripts, change public
interfaces, alter runtime output, update documentation, or make unrelated
improvements.

The implementation in the current `Beta` branch is the source of truth.

======================================================================
BRANCH SAFETY
======================================================================

Before changing any files:

1. Fetch all current remote references.
2. Verify that `origin/Beta` exists using the exact branch name and case.
3. Record the current `origin/Beta` commit SHA.
4. Create a new dedicated working branch from the current `origin/Beta`.
5. Verify that the branch is based on `origin/Beta`, not `main`.

Suggested branch name:

    chore/prune-lib-comments

Commands should be equivalent to:

    git fetch --all --prune
    git switch --create chore/prune-lib-comments origin/Beta

Do not:

- Base the work on `main`.
- Merge `main` into the working branch.
- Rebase onto `main`.
- Fall back to `main` if `origin/Beta` is unavailable.
- Include changes from another feature branch.

If `origin/Beta` does not exist, stop and report the available remote branches.

======================================================================
STRICT SCOPE
======================================================================

Files permitted to change:

    lib/*.sh

Include nested shell files under `lib/` if any exist.

Files outside `lib/` must not be changed.

Permitted changes:

- Delete unnecessary comments.
- Shorten or rewrite retained comments.
- Correct inaccurate comments.
- Correct structured library headers so they match the current file.
- Adjust blank lines left behind by comment removal.
- Make minimal comment-only formatting changes.

Not permitted:

- Functional code changes.
- Refactoring.
- Function renaming.
- Variable renaming.
- Moving functions.
- Reordering code.
- Changing command behavior.
- Changing conditions or control flow.
- Changing exit codes.
- Changing traps.
- Changing paths.
- Changing permissions.
- Changing configuration keys.
- Changing public interfaces.
- Changing source order.
- Changing dependency behavior.
- Adding architecture helpers.
- Removing dead code.
- Changing runtime logging.
- Changing help output.
- Updating README or `docs/`.
- Dependency or version updates.
- Formatting unrelated code.
- Fixing unrelated findings.

The final diff must be comment-only, apart from whitespace directly caused by
comment removal or rewriting.

If a code defect is discovered, do not fix it. Record it in the pull request
under `Out-of-scope observations`.

======================================================================
COMMENTS AND EXECUTABLE OUTPUT
======================================================================

A shell comment is text introduced by `#` that is not executable shell content.

The following are not ordinary comments and must not be removed as part of this
task:

- Shebangs such as:

      #!/usr/bin/env bash

- Shell or tool directives.
- ShellCheck suppression directives.
- License and copyright notices.
- Runtime logging calls.
- Operator prompts.
- Help and usage text.
- Executable `printf` or `echo` output.
- Here-document content used as generated configuration or runtime output.

Runtime logging is executable behavior.

Do not remove, rewrite, suppress, or relocate:

- `log_info`
- `log_warn`
- `log_error`
- `log_debug`
- Progress messages
- Status messages
- Operator prompts
- Runtime `printf` output
- Runtime `echo` output

This remains true even when the runtime message appears similar to a nearby
comment.

An existing runtime log may make a nearby narrative comment redundant, but the
runtime log itself must remain unchanged.

======================================================================
COMMENT-RETENTION POLICY
======================================================================

Comment deletion is the default.

A comment may remain only when it belongs to one of the approved categories
below.

----------------------------------------------------------------------
1. SHEBANG
----------------------------------------------------------------------

Preserve the interpreter line at the start of each shell file, for example:

    #!/usr/bin/env bash

The shebang is not a descriptive comment and must not be removed.

----------------------------------------------------------------------
2. STRUCTURED LIBRARY HEADER
----------------------------------------------------------------------

Preserve structured module or library headers at the beginning of files under
`lib/`.

A structured library header may include:

- The file name.
- A concise description of the library’s purpose.
- A categorized inventory of public functions.
- Exported variables or constants.
- Required dependencies.
- Required source or load order.
- Initialization requirements.
- A canonical caller or source block.
- Important usage constraints applying to the entire library.

For example, a header in this form should be retained:

    #!/usr/bin/env bash
    # lib/common.sh — Core utility functions for VaultWarden-OCI.
    #
    # Provides:
    #   Privilege    : is_root, require_root, get_real_user, _maybe_sudo,
    #                  auto_fix_critical_permissions
    #   System       : has_command, require_commands, retry_with_backoff,
    #                  _require_script
    #   Filesystem   : ensure_dir, secure_file
    #   Network/IO   : test_connectivity, test_http, download_file
    #   Lifecycle    : register_cleanup, perform_cleanup, setup_error_trap,
    #                  setup_cleanup_trap, safe_execute, init_common_lib
    #   Architecture : HOST_ARCH, GITHUB_ARCH
    #
    # Load order:
    #   Source lib/log.sh before this file because common.sh uses its logging
    #   functions. Source lib/config.sh first when configuration helpers are
    #   required.
    #
    # Canonical source block:
    #   source "${LIB_DIR}/log.sh"
    #   source "${LIB_DIR}/config.sh"   # When configuration helpers are needed.
    #   source "${LIB_DIR}/common.sh"
    #   init_common_lib "$0"

Do not aggressively shorten structured library headers.

Keep them accurate:

- Remove references to functions that no longer exist.
- Add missing public functions only when necessary for header accuracy.
- Correct exported-variable lists.
- Correct dependency and load-order information.
- Correct canonical source examples.
- Preserve useful categorization.

Do not add:

- Internal implementation walkthroughs.
- Function-by-function prose descriptions.
- Historical context.
- Future plans.
- Detailed control-flow explanations.

A small library does not need a large interface inventory. Retain or use a
concise one-line library header when that is sufficient.

----------------------------------------------------------------------
3. PHASE AND SECTION HEADINGS
----------------------------------------------------------------------

Preserve concise headings that make a long library easier to navigate.

Examples:

    # Privilege helpers
    # Filesystem operations
    # Cleanup and signal handling
    # Backup validation
    # Public API

Headings should:

- Identify a meaningful group of related functions.
- Improve visibility when scanning the file.
- Remain short.
- Match the functions below them.

Remove headings that:

- Precede only one trivial statement.
- Repeat the immediately following function name.
- Divide code into excessively small sections.
- No longer match the code below them.
- Exist only as visual decoration.

Do not add headings for every function.

----------------------------------------------------------------------
4. FUNCTION IDENTIFICATION
----------------------------------------------------------------------

A concise function-level comment may remain when it materially helps identify:

- The function’s public contract.
- A non-obvious input or output.
- A side effect relevant to callers.
- A requirement callers must satisfy.
- A meaningful distinction from similarly named functions.

Remove comments that merely restate the function name.

For example, remove:

    # Check whether the user is root.
    is_root() {
        ...
    }

The function name is already sufficient.

A retained function comment should communicate information that cannot be
obtained immediately from the name and signature.

----------------------------------------------------------------------
5. ADMINISTRATOR CONFIGURATION
----------------------------------------------------------------------

Retain comments that tell an administrator or caller:

- Which value must be supplied.
- Which setting must be changed.
- Which path must be configured.
- Which identifier must be obtained externally.
- Which option is required or optional.
- Which environment variable controls behavior.
- Which load order or initialization call is required.

These comments must be directly relevant to configuration or correct use.

Do not classify internal implementation details as administrator configuration.

----------------------------------------------------------------------
6. SAFETY WARNINGS
----------------------------------------------------------------------

Retain concise warnings immediately before code involving:

- Destructive filesystem operations.
- Irreversible operations.
- Privileged changes.
- Secret replacement or deletion.
- Restore operations that may overwrite data.
- Backup deletion.
- Storage formatting or repartitioning.
- Security-sensitive behavior where misuse creates a realistic risk.

The warning must explain the actual risk.

Remove generic warnings that do not help prevent a specific unsafe action.

----------------------------------------------------------------------
7. FALSE-POSITIVE PREVENTION
----------------------------------------------------------------------

Retain a brief comment only when intentional code is realistically likely to be
incorrectly flagged by:

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
- A security-sensitive exception to an otherwise expected rule.
- A command that appears redundant but prevents a known race or data-loss case.
- A ShellCheck suppression requiring justification.
- Deliberately unusual quoting or expansion required by an external interface.

The following do not automatically qualify:

- Non-obvious implementation details.
- Normal package-manager behavior.
- Normal shell behavior.
- Phase-to-phase dependencies.
- Temporary intermediate files.
- Compatibility workarounds.
- Execution ordering.
- An unusual command.
- Code that merely benefits from explanation.

Retain a false-positive comment only when removing it creates a realistic risk
that required code will be incorrectly flagged or removed.

Keep it as short as possible.

======================================================================
COMMENTS TO REMOVE
======================================================================

Remove comments that:

- Narrate the next command.
- Restate what the code visibly does.
- Explain normal control flow.
- Explain an `if`, `case`, loop, assignment, or return that is already clear.
- Explain that one step prepares data for a later step.
- Describe temporary or intermediate variables.
- Describe temporary or intermediate files.
- Explain routine package-manager behavior.
- Explain routine command behavior.
- Explain why a file is created, copied, moved, or deleted when that purpose is
  already apparent from the code or function name.
- Describe internal implementation details irrelevant to callers.
- Repeat a nearby runtime log.
- Repeat a function name.
- Repeat a variable name.
- Repeat a condition.
- Repeat documentation elsewhere.
- Contain historical context.
- Describe an earlier implementation.
- Contain stale TODO items.
- Contain speculative future work.
- Are conversational.
- Are tutorial-like.
- Are excessively verbose.
- Exist because code is poorly named.
- Explain obvious shell syntax.
- Add no safety, interface, configuration, navigation, or false-positive value.

Comments like the following should normally be removed:

    # Pre-create a minimal stub config so the package postinst script does
    # not abort trying to open a non-existent config file. Phase 6 overwrites.

Do not retain comments merely because they explain why an implementation step
exists.

Do not replace removed comments with new runtime logging.

Do not alter code merely to make a comment removable.

======================================================================
INLINE COMMENTS
======================================================================

Review inline comments separately.

Example:

    value="${VALUE:-}"  # Leave blank to resolve automatically.

Retain an inline comment only when it communicates:

- A required configuration choice.
- A safety constraint.
- A non-obvious public contract.
- A narrow false-positive justification.

Remove inline comments that:

- Restate the assignment.
- Repeat the variable name.
- Explain obvious syntax.
- Duplicate a surrounding header.
- Duplicate help or configuration documentation.

Do not reformat executable code unnecessarily when removing an inline comment.

======================================================================
BLANK LINES AND VISUAL STRUCTURE
======================================================================

After removing comments:

- Remove excess blank lines left behind.
- Preserve clear separation between functions.
- Preserve spacing around major sections.
- Do not collapse the file into a dense block.
- Do not perform unrelated formatting.
- Do not reindent or reflow executable code unless directly required by comment
  removal.

The resulting files should remain easy to scan.

======================================================================
CLASSIFICATION OF RETAINED COMMENTS
======================================================================

During review, classify each retained comment or comment block internally as
one of:

- LIBRARY-HEADER
- SECTION-HEADING
- FUNCTION-CONTRACT
- ADMIN-CONFIG
- SAFETY-WARNING
- FALSE-POSITIVE
- REQUIRED-DIRECTIVE
- LICENSE

Shebangs are tracked separately.

If a comment cannot be placed in one of these categories, remove it.

Runtime logging and executable output are not part of this classification.

Do not add classification labels to the source files.

======================================================================
VALIDATION
======================================================================

Because this task must not change behavior, validate that all changes are
comment-only.

Run at least:

1. Shell syntax validation for all shell files under `lib/`:

       find lib -type f -name '*.sh' -print0 |
         xargs -0 -n1 bash -n

2. ShellCheck using the repository’s established command.

3. Existing tests covering the libraries.

4. Repository-provided lint or validation commands relevant to `lib/`.

5. A diff review:

       git diff --word-diff=porcelain origin/Beta...HEAD
       git diff --check
       git status --short

6. A non-comment behavior comparison.

Use an appropriate parser or comparison process to confirm that executable
shell content is unchanged apart from whitespace directly caused by comment
removal.

Do not rely only on visual inspection.

At minimum, compare versions of each changed file after excluding:

- Shebang handling as appropriate.
- Standalone shell comments.
- Permitted inline comments.
- Blank lines.

Review any detected executable difference manually.

Confirm that:

- No function body behavior changed.
- No function names changed.
- No variables changed.
- No commands changed.
- No arguments changed.
- No conditions changed.
- No source order changed.
- No logging call changed.
- No prompt changed.
- No help text changed.
- No heredoc payload changed.
- No file outside `lib/` changed.

If a test or check fails before changes and still fails afterward, record it as
a pre-existing baseline failure.

Do not claim that a check passed when it was not run.

======================================================================
COMMENT AUDIT METRICS
======================================================================

Report:

- Number of `lib/` files reviewed.
- Number of `lib/` files changed.
- Number of standalone comments removed.
- Number of inline comments removed.
- Number of comments rewritten.
- Number of structured library headers retained.
- Number of structured library headers corrected.
- Number of section headings retained.
- Number of function-contract comments retained.
- Number of administrator-configuration comments retained.
- Number of safety warnings retained.
- Number of false-positive comments retained.
- Number of required directives retained.
- Confirmation that runtime logging was excluded from comment metrics.
- Confirmation that no runtime log was removed or rewritten.

For every retained FALSE-POSITIVE comment, provide:

- File path.
- Line or function context.
- Brief reason it is necessary.

Do not report exact metrics until the final diff is complete.

======================================================================
CHECKLIST
======================================================================

Maintain this checklist during the task.

Branch and scope
- [ ] Fetch current remote references.
- [ ] Verify `origin/Beta`.
- [ ] Record the original `origin/Beta` SHA.
- [ ] Create a new branch from `origin/Beta`.
- [ ] Confirm the branch is not based on `main`.
- [ ] Confirm the working tree has no unprotected pre-existing changes.
- [ ] Inventory every shell file under `lib/`.
- [ ] Confirm that no file outside `lib/` is in scope.

Comment review
- [ ] Review every top-of-file library header.
- [ ] Preserve or correct structured library interface headers.
- [ ] Review every phase and section heading.
- [ ] Review every function-level comment.
- [ ] Review every inline comment.
- [ ] Remove narrative comments.
- [ ] Remove implementation-explanation comments.
- [ ] Remove comments duplicated by runtime logging.
- [ ] Remove stale or inaccurate comments.
- [ ] Preserve administrator-configuration comments.
- [ ] Preserve safety warnings.
- [ ] Preserve narrow false-positive comments.
- [ ] Preserve required directives.
- [ ] Preserve license notices.
- [ ] Preserve all shebangs.
- [ ] Preserve all runtime logging.
- [ ] Remove excess blank lines left by pruning.

Validation
- [ ] Confirm the diff is comment-only.
- [ ] Confirm executable shell behavior is unchanged.
- [ ] Run `bash -n` for all shell files under `lib/`.
- [ ] Run ShellCheck.
- [ ] Run relevant existing tests.
- [ ] Run repository lint or validation commands relevant to `lib/`.
- [ ] Run `git diff --check`.
- [ ] Confirm no runtime log changed.
- [ ] Confirm no heredoc payload changed.
- [ ] Confirm no file outside `lib/` changed.
- [ ] Record pre-existing failures separately.
- [ ] Complete comment audit metrics.

Pull request
- [ ] Create logical comment-only commit or commits.
- [ ] Fetch the latest `origin/Beta`.
- [ ] Synchronize with `origin/Beta` if required.
- [ ] Rerun affected validation after synchronization.
- [ ] Push the working branch.
- [ ] Create a new PR targeting `Beta`.
- [ ] Verify the PR base is `Beta`.
- [ ] Verify the PR head is the dedicated working branch.
- [ ] Include audit metrics in the PR body.
- [ ] Include validation results in the PR body.
- [ ] Include retained false-positive justifications.
- [ ] Include out-of-scope observations.

For a non-applicable item, use:

    [x] Not applicable — <specific reason>

Do not silently omit checklist items.

======================================================================
COMMITS
======================================================================

Use a focused commit message such as:

    chore: prune narrative comments from shell libraries

If multiple commits materially improve reviewability, acceptable examples are:

    chore: prune comments from core shell libraries
    chore: align remaining library headers and comments

Do not mix code changes into these commits.

Before pushing:

1. Fetch the latest `origin/Beta`.
2. Determine whether `Beta` advanced.
3. Update against `origin/Beta` if needed.
4. Do not update against `main`.
5. Rerun validation after synchronization.
6. Confirm a clean working tree.

======================================================================
PULL REQUEST
======================================================================

Push the branch and create a new pull request with:

    Base: Beta
    Head: chore/prune-lib-comments

Use the actual head branch name if it differs.

Suggested PR title:

    Prune narrative comments from shell libraries

The PR body must contain:

## Summary

Explain that the PR:

- Prunes unnecessary comments under `lib/`.
- Preserves structured library headers.
- Preserves navigation headings.
- Preserves administrator configuration guidance.
- Preserves safety warnings.
- Preserves narrowly justified false-positive comments.
- Preserves runtime logging.
- Does not intentionally change executable behavior.

## Scope

State explicitly:

- Only files under `lib/` were reviewed.
- Only comments and directly resulting whitespace were changed.
- No script behavior was intentionally changed.
- No documentation was updated.
- No dependency or version changes were made.

## Comment policy

Summarize the retained categories:

- Structured library headers.
- Section headings.
- Function contracts.
- Administrator configuration.
- Safety warnings.
- False-positive prevention.
- Required directives.
- License notices.

State that narrative and implementation-explanation comments were removed by
default.

## Audit metrics

Include all required comment metrics.

## Retained false-positive comments

List every retained FALSE-POSITIVE comment with:

- File.
- Context.
- Reason for retention.

If none remain, state:

    None.

## Validation

List every validation command and result.

Clearly identify:

- Passed checks.
- Pre-existing failures.
- Checks that could not be run.
- Substitute validation used.

## Runtime logging

Confirm:

- Runtime logging was treated as executable behavior.
- No useful `log_info`, `log_warn`, `log_error`, `log_debug`, prompt, progress,
  or status message was removed.
- No runtime logging was rewritten unless required to correct a defect; such a
  correction would be outside normal scope and must be separately justified.

The expected result for this task is that no runtime logging changes are needed.

## Out-of-scope observations

List defects or improvement opportunities found but not changed.

If none were found, state:

    None identified.

## Checklist

Include the completed task checklist.

======================================================================
COMPLETION CONDITIONS
======================================================================

The task is complete only when:

- Every shell file under `lib/` was reviewed.
- Structured library headers were retained and kept accurate.
- Narrative comments were removed by default.
- Implementation-explanation comments were removed by default.
- Runtime logging was preserved.
- No executable behavior intentionally changed.
- No file outside `lib/` changed.
- Validation completed successfully or limitations were reported honestly.
- The branch was pushed.
- A new PR was created against `Beta`.
- The PR base and head were inspected and confirmed.
- The PR body contains the comment metrics.
- The PR body contains validation results.
- The PR body contains retained false-positive justifications.
- The PR body contains the completed checklist.

The final response must include:

- Pull-request URL.
- PR title.
- Base branch.
- Head branch.
- Original `origin/Beta` SHA.
- Final head SHA.
- Commit summary.
- Files reviewed.
- Files changed.
- Comment audit metrics.
- Validation summary.
- Pre-existing failures.
- Checks that could not be run.
- Remaining limitations.
- Confirmation that the PR base is `Beta`.

Do not stop after producing an audit or proposed patch.

Complete the comment pruning, validate it, push the branch, and open the pull
request.