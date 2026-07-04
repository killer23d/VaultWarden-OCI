# Operator UI Preliminary Scan

## Executive Summary

VaultWarden-OCI already has unusually strong operator-safety instincts for a shell-managed service. The restore, storage, uninstall, startup, backup, and setup flows all contain real safeguards: explicit destructive confirmations, TTY-aware logging, non-interactive guards, JSON/quiet modes where they matter, and repeated reminders around disaster recovery material.

The terminal UI is not uniformly polished, though. The main risk is not that the scripts are careless. It is that important prompts, summaries, and key/passphrase language are implemented locally in many different ways. Under stress, especially during disaster recovery, a junior operator may miss which action is destructive, which key is being requested, or whether a final success message actually means the service is healthy.

Top findings:

1. `recover.sh` can report that recovery is complete and Vaultwarden is running even after the health check fails. This should be fixed first.
2. `utilities/maintenance-db-maint.sh` defaults to continuing deep offline maintenance when its 30-second confirmation prompt times out, while the prompt does not disclose that default. This should also be fixed first.
3. High-stakes prompts are strong in content but inconsistent in shape. A small shared operator UI layer would make destructive confirmations, key/passphrase prompts, and final next-step summaries easier to recognize without rewriting the whole project.

Recommended near-term scope: fix only the two concrete misleading/surprising behaviors first, then add a small helper layer later after the team agrees on the terminal UX policy.

## What Already Works Well

- `lib/log.sh` is a good foundation. It centralizes log levels, TTY-aware color, timestamps, dry-run prefixes, stderr routing for warnings/errors, and progress helpers.
- `lib/common.sh` already has `press_enter_to_continue`, which is useful for key custody and recovery-kit moments where a human pause is intentional.
- `setup.sh` has a strong `--force` warning and an explicit `VW_FORCE_ACK=I_UNDERSTAND_LOSING_OLD_BACKUPS` gate before rotating the Age key. The post-install summary is also recovery-oriented and keeps critical credentials visible.
- `utilities/restore-run.sh` is the best current example of operator education. Its help and key prompts clearly distinguish the selected backup Age key, the live SOPS key, pre-restore emergency snapshot passphrases, and the new post-restore operational Age key.
- `lib/storage.sh` is conservative around destructive storage actions. Existing filesystems require exact confirmation, and non-interactive format behavior is gated behind environment variables.
- `utilities/uninstall-vaultwarden.sh` has strong pre-destruction safeguards, including final-backup offers, exact `UNINSTALL` and `DELETE-BACKUPS` confirmations, and an Age key safety gate.
- `startup.sh` aggregates warnings and repeats important Age-key recovery guidance near the end, which is the right place for information that operators might otherwise miss in scrolling logs.
- `utilities/backup-run.sh`, `lib/backup-utils.sh`, and `utilities/maintenance-health.sh` respect machine-readable paths such as `--json` and `--quiet`. Human terminal improvements should preserve that behavior.
- `utilities/maintenance-run.sh` gives a useful final summary after routine maintenance and uses locks around operations.
- `lib/migrate.sh` already contains local confirm helpers and structured migration summaries. That is a good precedent for introducing shared prompt helpers gradually.

## High-Confidence Findings

### UI-01: `recover.sh` reports success even when health check fails

Severity: High
Confidence: High
Fix priority: Fix now

Relevant files:

- `recover.sh:333-350`

Current behavior:

- `run_startup_health` runs `./startup.sh`, waits 10 seconds, then checks `https://$DOMAIN/alive`.
- If the health check succeeds, it prints `Health check: PASS`.
- If the health check fails, it prints `Health check: FAIL`, points to the startup log, and continues.
- It then prints `Recovery complete. Vaultwarden is running at $DOMAIN` unconditionally.

Why this matters:

During disaster recovery, a junior operator may treat the final line as authoritative. If the health check failed, the script should not say that Vaultwarden is running. This is a terminal UX problem with operational impact: the final message can contradict the immediately preceding failure and cause the operator to stop investigating.

Suggested direction:

- Split "recovery artifacts promoted" from "service is healthy".
- On health-check failure, print a final warning such as `Recovery artifacts were promoted, but Vaultwarden did not pass the health check`.
- Include concrete next commands: startup log, `docker compose ps`, `docker compose logs`, and the `/alive` URL.
- Consider returning a non-zero exit code when startup health fails, unless callers depend on the current behavior.
- If non-zero exit is too risky for a first patch, still make the final text unambiguous and avoid saying "running".

### UI-02: Deep database maintenance proceeds on prompt timeout

Severity: Medium
Confidence: High
Fix priority: Fix now

Relevant files:

- `utilities/maintenance-db-maint.sh:73-80`

Current behavior:

- The script warns that deep database maintenance stops Vaultwarden briefly.
- It prompts: `Continue with deep database maintenance? [yes/no]:`
- If the 30-second `read` times out, it sets `confirm="yes"`.
- The prompt text does not disclose that timeout means yes.

Why this matters:

This is a surprising default for a disruptive operation. A distracted operator or an unattended terminal can cross the confirmation boundary and stop the service. The script already has `--force` for intentional automation, so the interactive path should fail closed.

Suggested direction:

- Change timeout fallback to no.
- Make the prompt text explicit, for example: `Continue with deep database maintenance? [yes/no] (default: no):`
- Keep `--force` as the automation override.
- If a timeout occurs, log that maintenance was cancelled because no confirmation was received.

### UI-03: High-stakes prompts are strong but visually inconsistent

Severity: Medium
Confidence: High
Fix priority: Fix later, after UI-01 and UI-02

Relevant files:

- `setup.sh:253-268`
- `utilities/restore-run.sh:2540-2553`
- `utilities/key-rotate.sh:217-223`
- `utilities/uninstall-vaultwarden.sh:877-889`
- `lib/storage.sh:166-209`
- `lib/secrets.sh:1490-1505`
- `lib/migrate.sh:202-214`

Current behavior:

- Many flows have carefully written warnings and confirmations.
- Each flow implements its own prompt style: exact words, yes/no prompts, typed acknowledgements, path echoes, timeout behavior, and formatting all vary.
- Some prompts are visually boxed and very prominent; others are plain `read -p` lines after log output.

Why this matters:

The project has several different "stop and decide" moments: rotate Age key, overwrite data during restore, format disks, delete backups, uninstall, remove emergency admin access, and rekey secrets. A junior operator benefits from a consistent visual grammar for those moments. Today, the content is usually good, but the shape is inconsistent enough that an important prompt can look like routine script chatter.

Suggested direction:

- Add a small shared helper layer instead of rewriting every script.
- Start with helpers for:
  - attention blocks
  - exact confirmations
  - yes/no confirmations with explicit defaults and timeouts
  - final next-step summaries
  - secret/key prompts with consistent TTY and timeout behavior
- Adopt the helper only in newly touched high-stakes paths first.
- Preserve specialized existing gates such as `VW_FORCE_ACK`, `DATA_VOLUME_FORCE_FORMAT`, exact filesystem confirmations, and uninstall's key-safety checks.

### UI-04: Key and passphrase roles are clearest in restore, less clear elsewhere

Severity: Medium
Confidence: High
Fix priority: Fix now for `recover.sh` wording, later elsewhere

Relevant files:

- `utilities/restore-run.sh:145-235`
- `utilities/restore-run.sh:986-1038`
- `recover.sh:167-191`
- `recover.sh:226-302`
- `utilities/backup-run.sh:1240-1263`
- `utilities/key-rotate.sh:217-223`
- `utilities/setup-secrets.sh:1919-1931`
- `utilities/setup-secrets.sh:2384-2398`

Current behavior:

- Restore does a very good job explaining which key/passphrase is needed and why.
- `recover.sh` performs several sensitive key operations, but the terminal story is much thinner:
  - it accepts an offline recovery private key path
  - decrypts a manifest
  - generates a new operational Age key
  - stages and promotes rekeyed secret artifacts
  - updates environment files
- Emergency backup can delegate the passphrase prompt to `age -p`, which is functional but not very project-specific.
- Setup allows the offline recovery Age recipient to be skipped with a simple Enter prompt, but the consequence is not emphasized in the terminal summary.

Why this matters:

In this repository, there are multiple secrets that sound similar during an incident:

- the live operational SOPS Age key
- the offline recovery Age key
- a selected backup's decrypt key
- an emergency backup passphrase
- a newly generated operational Age key after recovery
- recovery-kit material

The restore flow proves the project knows how to explain these distinctions. The same policy should be reused in disaster recovery and key-rotation-adjacent flows.

Suggested direction:

- For `recover.sh`, print a short preflight plan before rekeying:
  - which offline key path is being used
  - which manifest is being decrypted
  - where staged artifacts will be created
  - that a new operational Age key will replace the old operational key
  - that the offline recovery key is not the new operational key
- For emergency backup, add one line before `age -p` explaining that this passphrase protects only the emergency backup capsule.
- For setup, summarize whether an offline recovery recipient was configured and what skipping it means.

### UI-05: Final summaries and next steps vary in prominence

Severity: Low to Medium
Confidence: High
Fix priority: Fix later

Relevant files:

- `setup.sh:276-437`
- `utilities/restore-run.sh:1501-1517`
- `utilities/setup-crowdsec.sh:1354-1431`
- `utilities/backup-run.sh:1676-1716`
- `startup.sh:795-805`
- `utilities/maintenance-run.sh:158-173`

Current behavior:

- Some flows end with excellent summaries and warnings.
- Some flows end with minimal success text.
- Some flows print very long summaries where the most important manual action can be buried.

Examples:

- `startup.sh` repeats accumulated warnings at the end. This is good.
- `restore-run.sh` prints a compact post-restore summary. This is good.
- `setup-crowdsec.sh` prints a long final summary, but the Cloudflare Worker fail-open manual action is easy to miss.
- `backup-run.sh` can complete with success lines but does not always give a concise terminal summary of backup type, selected destination, verification status, and offsite sync result.

Suggested direction:

- Introduce a shared "next steps" helper for the final screen of long-running operations.
- Keep details in logs, but make the last screen answer:
  - What changed?
  - Is the service healthy?
  - What must I save?
  - What must I do manually?
  - What command verifies the result?

## Medium/Low-Confidence Observations

- `utilities/setup-crowdsec.sh:1413-1416` includes an important Cloudflare Worker fail-open reminder, but it appears inside a long log-style final summary. This probably deserves a top-positioned manual action when Cloudflare mode is used.
- `utilities/setup-secrets.sh:1919-1931` and `utilities/setup-secrets.sh:2384-2398` allow skipping the offline recovery Age public key with Enter. That can be a valid choice, but the terminal prompt should make the disaster-recovery consequence clearer.
- `Makefile:760-769` has an `update-system` target that runs host package updates directly. The richer `utilities/maintenance-update.sh` flow has pre-update backup and rollback-oriented messaging. Consider routing or wording the Make target so operators understand which update path they are using.
- `Makefile:867` removes break-glass emergency admin state through a `--force` utility invocation. That may be intentional for Make ergonomics, but it bypasses the direct utility's interactive confirmation.
- `utilities/restore-run.sh:1457-1482` prints a fixed-width restore plan box. Very long backup names or paths may overflow the box in narrow terminals.
- Early failure paths in thin dispatchers such as `maintenance.sh` and `recover.sh` use raw `echo`. That is acceptable for simple usage errors and should not drive a broad rewrite.
- `log_phase` output is visually useful for TTY sessions, but long script logs still vary a lot in density. This is a polish issue, not a correctness issue.
- Some prompts use lowercase `yes`, others use exact uppercase tokens such as `YES`, `UNINSTALL`, `DELETE-BACKUPS`, or `SAVED`. The exact-token approach is good for destructive flows, but the policy should be explicit.

## Candidate UX Policy

The following policy would fit the existing codebase without changing its operational model.

### Routine Progress

- Use `log_phase`, `log_info`, and `log_success`.
- Keep routine output concise.
- Do not require operator input.
- In dry-run mode, preserve the existing `[DRY RUN]` prefix behavior.

### Attention Blocks

Use an attention block when the operator must notice context but does not need to decide yet.

Examples:

- "You are about to rotate the operational Age key."
- "This restore uses a backup encrypted with a different key."
- "The offline recovery recipient was skipped."
- "CrowdSec setup requires a manual Cloudflare fail-open setting."

Policy:

- Print to stderr for warnings/errors.
- Use color only when TTY.
- Include 1 to 4 short lines.
- Avoid requiring input unless the next step is truly gated.

### Destructive Confirmations

Use a destructive confirmation when data, keys, backups, availability, or firewall access can be lost.

Policy:

- Show the target explicitly: device, path, backup id, domain, service, or key fingerprint.
- State the consequence in plain language.
- Prefer exact typed tokens for irreversible deletion or key loss.
- Default to no for interactive yes/no prompts.
- On timeout, cancel unless an explicit `--force` or documented environment override is present.
- In non-interactive mode, fail closed unless the script already has a clear automation gate.

### Secret and Key Prompts

Policy:

- Name the secret by role, not just by format.
- Distinguish:
  - live operational SOPS Age key
  - offline recovery Age key
  - selected backup decrypt key
  - emergency backup passphrase
  - recovery-kit contents
  - new operational Age key
- Use hidden input for private keys and passphrases where practical.
- Require TTY for interactive secret entry.
- Provide timeout behavior that fails closed.
- After generating a new private key, require an explicit save acknowledgement unless a documented automation flag is present.

### Final Summaries

Each long-running operator command should end with a compact final summary.

Preferred fields:

- result: success, partial success, failed, or cancelled
- service health: healthy, not checked, or failed
- data changed: yes/no and where
- keys changed: yes/no and which role
- backups created: path or id
- manual actions: top 1 to 3 items
- verification command: one command the operator can run next

### Machine-Readable and Automation Paths

Policy:

- Do not print human banners in `--json` output.
- Preserve `--quiet`.
- Preserve non-interactive behavior for systemd, cron, and Make targets.
- Do not add prompts to paths that are currently designed for automation.
- Use existing explicit gates such as `--force`, `VW_FORCE_ACK`, `DATA_VOLUME_FORCE_FORMAT`, and `DATA_VOLUME_EXISTING_FS_OK` rather than inventing competing flags.

## Candidate Helper Design

This should be a small addition, not a framework.

Likely location:

- Add to `lib/log.sh` if the helpers are mostly presentation-oriented.
- Add to `lib/common.sh` if they need input, timeout, TTY, and non-interactive behavior.
- A separate `lib/operator-ui.sh` is also reasonable if the team wants to avoid expanding `lib/log.sh`.

Candidate helpers:

```bash
operator_attention SEVERITY TITLE LINE...
```

Purpose:

- Print a consistent attention block.
- Does not prompt.
- Respects TTY color.
- Uses stderr for warn/error severities.

```bash
operator_confirm --prompt TEXT --default no --timeout 30
```

Purpose:

- Yes/no confirmation with explicit defaults.
- Timeout behavior is visible and fail-closed by default.
- Returns success only for affirmative confirmation.

```bash
operator_confirm_exact --prompt TEXT --expect TOKEN --target TARGET
```

Purpose:

- Exact typed acknowledgement for destructive operations.
- Displays the target and consequence consistently.
- Useful for delete, format, uninstall, key loss, and backup overwrite cases.

```bash
operator_secret_prompt --label TEXT --timeout 300 --allow-empty false
```

Purpose:

- Hidden input for private keys and passphrases.
- TTY-only by default.
- Can reuse the restore flow's countdown pattern later.

```bash
operator_next_steps TITLE ITEM...
```

Purpose:

- Print the final "what now" block after long-running flows.
- Keep only the top manual actions visible.
- Let detailed logs remain in the normal output above.

Implementation notes:

- Start by wrapping new or modified call sites only.
- Do not migrate all prompts at once.
- Keep helper output simple enough for plain terminals.
- Keep all messages ASCII-safe unless a script already depends on Unicode UI.
- Do not replace specialized safety flows until there is a testable reason.

## Files Worth Changing Later

### Change First

- `recover.sh`
  - Fix the misleading final health message.
  - Add a short DR preflight plan that distinguishes offline recovery key, new operational key, staged artifacts, and service health.

- `utilities/maintenance-db-maint.sh`
  - Change the deep-maintenance timeout default to no.
  - Make the prompt text disclose the default.

### Good Next Candidates

- `lib/log.sh`, `lib/common.sh`, or a new `lib/operator-ui.sh`
  - Add the minimal helper set after the first two concrete fixes.

- `utilities/restore-run.sh`
  - Keep the existing language, but use shared helpers for the final destructive overwrite confirmation and final summaries if a helper is introduced.

- `utilities/key-rotate.sh`
  - Standardize the initial "continue with Age key rotation" confirmation.
  - Preserve the strong final `SAVED` acknowledgement.

- `utilities/backup-run.sh`
  - Add a concise final summary and clearer emergency-backup passphrase wording.

- `utilities/setup-crowdsec.sh`
  - Promote required manual Cloudflare actions in the final summary.

- `utilities/setup-secrets.sh` and `lib/secrets.sh`
  - Clarify the consequence of skipping the offline recovery recipient.
  - Keep the existing recovery-kit pauses and warnings.

- `setup.sh`
  - Eventually use shared attention/summary helpers around the existing post-install summary.
  - Preserve the current `VW_FORCE_ACK` gate.

### Usually Leave Alone

- `lib/storage.sh`
  - The destructive storage gates are already strong. Touch only if adopting a shared helper with equal or stronger behavior.

- `utilities/uninstall-vaultwarden.sh`
  - The uninstall flow is already cautious. Do not simplify the exact confirmations.

- `startup.sh`
  - The final warning aggregation is good. Avoid making startup quieter at the cost of losing actionable warnings.

- `lib/backup-utils.sh`
  - Preserve JSON and table output behavior.

- `utilities/maintenance-health.sh`
  - Preserve `--json` and `--quiet` behavior.

- Thin dispatchers such as `backup.sh`, `restore.sh`, `edit-secrets.sh`, and `maintenance.sh`
  - Raw usage errors are acceptable unless the underlying command changes.

## Risks / Things Not To Do

- Do not hide or downgrade existing warnings about Age keys, recovery kits, storage formatting, backup deletion, or service health.
- Do not add prompts to `--json`, `--quiet`, systemd, cron, or non-interactive automation paths.
- Do not make `--force` broader than it already is.
- Do not weaken exact confirmations such as `UNINSTALL`, `DELETE-BACKUPS`, `SAVED`, path echo confirmations, or filesystem `YES` prompts.
- Do not replace clear domain-specific language with generic helper text.
- Do not run a broad formatting pass over the shell scripts as part of UI work.
- Do not turn every log message into a box. Attention blocks should be rare enough to mean something.
- Do not change backup, restore, rekey, or storage semantics while doing a terminal-copy cleanup unless the behavior change is explicitly reviewed.
- Do not let helper adoption break existing tests or shellcheck behavior.
- Do not rely on color alone. The terminal UI should remain understandable without color.

## Suggested Next Prompt

Use this follow-up prompt to implement only the safest, highest-value changes from this scan:

```text
Implement only the two highest-confidence operator UX fixes from reports/operator-ui-preliminary-scan.md.

Scope:
- Fix UI-01 in recover.sh so a failed /alive health check does not end with text saying Vaultwarden is running. Make the final status clearly say whether recovery artifacts were promoted and whether service health passed. Include actionable next commands on failure. Prefer a non-zero exit on failed health if that does not conflict with existing tests or documented behavior.
- Fix UI-02 in utilities/maintenance-db-maint.sh so the deep database maintenance confirmation times out to "no", the prompt states "(default: no)", and cancellation is logged clearly.

Constraints:
- Do not add the shared operator UI helper layer yet.
- Do not reformat unrelated shell files.
- Preserve non-interactive behavior, --force behavior, dry-run behavior, and existing safety gates.
- Add or update focused tests if there is an existing pattern for these scripts.
- Run available relevant tests. Run shellcheck/shfmt only if already installed; do not apply shfmt formatting unless explicitly requested.
- End with git status --short.
```
