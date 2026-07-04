# AGENTS.md — VaultWarden-OCI Agent Instructions

## Project context

This repository is a small-team, self-hosted Vaultwarden deployment for Oracle Cloud Infrastructure on Ubuntu.

The intended production user is a small workgroup, not an enterprise platform team. The operator may be a junior Linux/Docker administrator. Favor simple, explicit, recoverable procedures over clever abstractions.

Project priorities, in order:

1. Security first
2. Reliable backup and restore
3. Clear junior-operator UX
4. Minimal moving parts
5. Avoid enterprise-style complexity unless clearly justified

## Current branch focus

Primary working branch: `delta`

Recent context:

* A Production Readiness Review already exists at:

```text
reports/production-readiness-review-delta.md
```

* That report reviewed the pre-remediation `delta` commit:

```text
95e16776f4597df73f5ea860a44397e433414cbc
```

* PR #216 was merged into `delta` after that report.
* PR #216 addressed findings F-01 through F-08 from the original report.
* The current second-pass task should use the existing report as prior work, not repeat a full audit from scratch.

## How to use prior reports

When a review report already exists under `reports/`, treat it as a baseline.

Do:

* Read the prior report first.
* Reuse its scope, findings, validation notes, and known limitations.
* Identify what the first audit already covered.
* Identify what the first audit could not validate.
* Focus on likely missed issues, stale assumptions, and post-remediation regressions.
* Prefer targeted checks over broad re-audit.

Do not:

* Re-audit every file from scratch unless a serious issue points there.
* Restate all prior findings in detail.
* Rewrite the original report wholesale.
* Treat a historical report as wrong just because the code has since been fixed.
* Create noisy Low/Note findings unless they are useful.

## Important architecture assumptions

Preserve these unless the user explicitly asks for a design change:

* Lifecycle is root-operated.
* `sudo make up`, `sudo make restart`, and related lifecycle commands are expected.
* SOPS + Age is the secrets model.
* The offline Age key must never be stored on the server.
* Runtime Docker secrets are staged under:

```text
/run/vaultwarden-oci/secrets
```

* Persistent state defaults to:

```text
/var/lib/vaultwarden
```

* Backup tiers are:

```text
db
full
emergency
```

* Emergency backups may contain recovery material and must be independently protected.
* Cloudflare and CrowdSec are part of the intended security model.
* The project is for a small team and should avoid enterprise plugin frameworks, registries, or broad abstractions.

## Review style

When reviewing:

* Be skeptical, but do not invent theoretical issues.
* Prefer evidence from files, commands, and line references.
* Distinguish confirmed findings from low-confidence notes.
* Do not recommend large refactors for style alone.
* Do not change behavior unless it fixes a real bug, security issue, restore issue, backup issue, or operator confusion.
* Preserve existing shell style, logging style, comments, and yes/no prompt conventions.
* Keep changes small and targeted.
* If a finding is low confidence, document it as a note, not as a required fix.

## High-confidence findings

Only call something a finding when there is enough evidence to say it is a real issue.

A high-confidence finding should have most of the following:

1. Direct file, test, config, or command-output evidence
2. A clear explanation of why the behavior is wrong or risky for this project
3. A realistic impact on security, backup, restore, operations, CI, or junior-operator UX
4. A narrow, practical fix
5. A validation command or smoke test

Examples of high-confidence findings:

* A workflow path filter omits an important file, allowing future changes to skip CI.
* A script uses an unsafe permission mode.
* A compose service has a documented hardening gap.
* A static placeholder could become a real credential.
* A command path is misleading for a junior operator.

Examples that are not high-confidence findings:

* “This might fail at runtime” without evidence.
* “This script is long and should be refactored.”
* “Maybe Ubuntu behaves differently” without target evidence.
* “A future test would be nice” without a present defect.

Uncertain items should be classified as Notes or Runtime Validation Limits, not Findings.

## Second-pass review expectations

A second-pass review should not be a full production-readiness audit.

Its job is to answer:

1. What did the first PRR miss?
2. What did the first PRR explicitly not validate?
3. Did PR #216 fix F-01 through F-08 cleanly?
4. Did PR #216 introduce any obvious regression?
5. Are there any remaining Critical, High, or Medium issues before `delta` can be considered production-ready?
6. Are there stale report statements that need clarification in the new report?
7. Are there CI/process gaps that could let future important changes bypass validation?

## Change discipline

Do not make broad changes.

Allowed changes during review/report tasks:

* Add this `AGENTS.md` if missing.
* Add a second-pass report under `reports/`.
* Make small code fixes only if there is a clear Critical or High issue.

Do not do the following unless explicitly requested:

* Rewrite documentation wholesale.
* Change the root-operated model.
* Introduce new dependencies.
* Add enterprise plugin registries or large abstractions.
* Remove safety prompts unless they are demonstrably wrong.
* Change backup, restore, or recovery semantics without strong evidence.
* Treat local macOS-only validation failures as project bugs unless Ubuntu target behavior is also affected.

## Severity scale

Use this severity scale:

* Critical: likely data loss, secret exposure, restore failure, or production outage
* High: security, backup, restore, or recovery issue that should be fixed before production-ready release
* Medium: real hardening, reliability, CI, or UX issue worth fixing soon
* Low: cleanup, polish, defense-in-depth, or minor consistency issue
* Note: observation only, no action required

## Remediation snippet expectations

When raising a finding, include a practical remediation suggestion.

For each Critical, High, or Medium finding, provide:

1. Target file
2. Target function, service, workflow, or section
3. Minimal suggested change
4. A code snippet, YAML snippet, shell snippet, or diff-style example
5. Validation command to confirm the fix

Prefer small, reviewable snippets over broad rewrites.

Use this format:

````markdown
### Suggested remediation

Target:

`path/to/file`

Suggested change:

```diff
- old line
+ new line
````

Validation:

```bash
command-that-confirms-the-fix
```

````

Rules:

- Snippets are suggestions unless the task explicitly asks to patch code.
- Do not apply functional code changes during a report-only review unless a clear Critical or High issue is found.
- For Low findings, snippets are optional but helpful.
- For Notes or runtime validation limits, provide a validation command or smoke-test suggestion instead of pretending there is a confirmed code fix.
- If a safe snippet cannot be proposed without runtime testing, say so clearly.
- Never provide a broad rewrite when a narrow patch would solve the issue.

## Validation expectations

Run what is available in the environment.

Minimum useful checks:

```bash
git status --short
git branch --show-current
git rev-parse HEAD
bash -n backup.sh restore.sh startup.sh recover.sh maintenance.sh setup.sh edit-secrets.sh
find utilities lib -name '*.sh' -print0 | xargs -0 bash -n
git grep '0666' lib/common.sh || true
grep -n 'Restart=' systemd/vaultwarden-startup.service || true
grep -n '^ADMIN_TOKEN=' .env.example
grep -n 'subnet:' docker-compose.yml.example
````

If available, also run:

```bash
make test-unit
docker compose -f docker-compose.yml.example config
shellcheck -x --severity=warning $(find . -name '*.sh' -not -path './.git/*')
```

If a command cannot run because a tool is missing or because the environment is not Ubuntu-compatible, state that clearly.

## Missed-issue hunting guidance

For second-pass reviews, prioritize areas the prior report did not fully validate:

* Docker runtime behavior
* Compose parsing and service hardening interaction
* Postfix read-only filesystem compatibility
* Backup/restore behavior that requires real tools or state
* Emergency backup passphrase round-trip
* Systemd install/runtime behavior
* CI path filters and whether important files trigger validation
* Stale report conclusions after remediation
* Assumptions that depend on Ubuntu behavior but were reviewed on macOS

Avoid broad style comments.

## Reporting expectations

A review report should be concise and evidence-based.

A useful report answers:

1. What prior report was used as baseline?
2. What branch and commit were reviewed?
3. Which files were inspected and why?
4. Which prior findings were verified as fixed?
5. What areas were intentionally not re-audited?
6. What likely missed issues were checked?
7. Which commands were run?
8. Which commands could not be run and why?
9. Are there any Critical, High, or Medium findings?
10. What exact file/line evidence supports each finding?
11. What is the recommended next action?

Avoid speculation. If runtime validation is required, say so directly.
