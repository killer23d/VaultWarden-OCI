# AGENTS.md — VaultWarden-OCI Repository Instructions

## Purpose

This file contains durable repository-level instructions for any AI coding or review agent working on VaultWarden-OCI.

It is intentionally task-agnostic. Do not turn it into a PR checklist, issue-specific prompt, audit log, or historical remediation record.

A task prompt may narrow scope further. It must not silently override the repository's supported production boundary, security model, or explicit operator contracts unless the task is specifically changing one of those contracts.

The current repository state is the implementation source of truth. Historical reports, old pull requests, comments, and prior agent conclusions are context only.

## Project identity

VaultWarden-OCI is a security-first, self-running Vaultwarden appliance for a small production deployment.

The design target is a small team, roughly ten users, with one primary operator who may be a junior Linux or Docker administrator. The system should be safe, understandable, mostly set-and-forget, and recoverable without enterprise infrastructure.

This is not:

- a generic Vaultwarden deployment framework;
- a multi-tenant hosting platform;
- a Kubernetes or HA product;
- a cloud-provider abstraction layer;
- an excuse to introduce enterprise architecture for hypothetical future scale.

Prefer the smallest coherent fix that preserves clear production behavior.

Repository priorities are:

1. Security and secret custody.
2. Reliable backup, restore, and disaster recovery.
3. Truthful success, failure, readiness, and operator state.
4. Safe concurrency and interruption behavior.
5. Simple operator workflows.
6. Useful automation and failure notification.
7. Minimal moving parts.
8. Portability across the explicitly supported production matrix.

## Supported production boundary

Read `docs/PROJECT-BOUNDARY.md` before changing installation, runtime architecture, platform support, or first-run behavior.

The supported normal production path is:

- Ubuntu 24.04 LTS Noble;
- amd64 or arm64;
- systemd;
- Docker Engine with the Docker Compose plugin;
- Cloudflare DNS, proxy, and WAF;
- Caddy using the repository's Cloudflare-first TLS path;
- Vaultwarden;
- Postfix where used by the current mail design;
- CrowdSec with Cloudflare edge enforcement;
- SOPS + Age encrypted secrets;
- rclone/offsite backup support;
- systemd automation for recurring production jobs.

The host runtime is provider-neutral. The project name is historical branding and does not make Oracle Cloud Infrastructure a runtime dependency.

Do not silently widen support to another Ubuntu release, CPU architecture, init system, container runtime, cloud provider integration, or edge provider.

Do not describe the stack as fully CPU agnostic. The supported architecture contract is amd64 and arm64.

When support detection fails or returns an unknown platform, fail clearly. Never default an unknown host or architecture to the most convenient supported value.

## Source-of-truth order

When repository surfaces disagree, investigate rather than choosing the most convenient text.

Use this order:

1. Current executable behavior and explicit safety checks.
2. Canonical configuration/default owners such as `lib/defaults.sh`, `lib/config.sh`, and the relevant owning library or utility.
3. Tests that protect an intentional production contract.
4. systemd, Compose, Make, dashboard, and automation callers.
5. Generated documentation source/generator.
6. Hand-maintained documentation.
7. Historical reports and prior PR discussion.

Tests can also be stale. A passing test is evidence, not proof that the asserted behavior is still the intended contract.

## Scope discipline

Before adding a framework, registry, state store, daemon, or abstraction, ask whether the defect can be fixed by:

- correcting the owning function;
- correcting one or more callers;
- reusing an existing canonical helper;
- removing misleading behavior;
- tightening one local transaction boundary;
- adding one explicit platform mapping;
- adding a focused regression test.

Prefer that solution.

Do not introduce without a demonstrated production requirement:

- Kubernetes or Docker Swarm orchestration;
- multi-node HA;
- distributed locks;
- Redis or another coordination service;
- a workflow engine;
- an operation or audit database;
- a generic transaction framework;
- a recovery state machine;
- a generic CLI parser framework;
- a command, provider, plugin, or policy registry;
- a generic cloud-provider abstraction;
- a generic architecture abstraction;
- a new daemon or scheduler;
- a second secrets manager;
- a new monitoring stack;
- broad rewrites for line-count reduction or stylistic uniformity.

Use the repository's existing Bash, Make, systemd, Docker Compose, SOPS/Age, and focused test architecture.

## Change workflow

Before editing:

1. Confirm the branch/ref and inspect the current file, not a remembered version.
2. Read the task and identify its exact scope.
3. Inspect nearby code and the canonical owner of the behavior.
4. Search all callers and public entry points.
5. Inspect the closest permanent tests.
6. Check systemd, Make, dashboard, workflows, generated docs, and operator docs when the contract crosses those surfaces.
7. Identify security, privilege, concurrency, interruption, and rollback boundaries.

During editing:

- keep the diff bounded to the requested outcome;
- preserve established architecture unless current evidence requires a change;
- reuse existing helpers and conventions;
- remove obsolete code rather than layering compatibility around dead internal behavior;
- preserve intentional compatibility aliases only when they have current callers or documented operator value;
- add focused regression coverage for corrected production behavior;
- do not perform unrelated cleanup merely because the file is open.

After editing:

- inspect the complete diff;
- verify no accidental files or generated artifacts are present;
- run the strongest safe applicable validation;
- report exactly what was and was not run.

Never claim a test, CI check, command, host validation, or architecture combination passed when it was not actually validated.

## Shell and Bash rules

The repository is Bash-oriented. Follow neighboring style and preserve Bash 5 compatibility where the repository requires it.

For production shell code:

- prefer `#!/usr/bin/env bash`;
- use `set -euo pipefail` where consistent with the owning script;
- quote parameter expansions unless intentional word splitting is required;
- use arrays for command argument lists;
- use `[[ ... ]]` for Bash conditionals;
- use `local` for function-local variables;
- validate required option values before shifting parser arguments;
- keep cleanup reliable with traps where temporary sensitive state exists;
- return meaningful non-zero status for real failure;
- do not hide a real failure behind `|| true`;
- be careful with commands whose successful-looking result can return non-zero under `set -e`;
- be careful with arithmetic expressions such as post-increment under errexit;
- keep help and version paths side-effect free;
- avoid sourcing production state merely to print static metadata when practical.

Do not add shell abstractions solely to make code look uniform.

## Privilege model

The supported production lifecycle is root-operated.

Normal operator forms intentionally include commands such as:

```bash
sudo make up
sudo make down
sudo make restart
sudo make health
sudo make backup
sudo make restore
```

First-time installation follows the current `setup.sh` grammar documented by the repository.

Do not redesign production around an unprivileged Docker-group operator.

Metadata and help paths may remain root-free when intentionally supported. Real privileged mutation must enforce root before meaningful mutation begins.

When changing privilege behavior, inspect:

- direct script invocation;
- Make targets;
- dashboard callers;
- systemd execution;
- nested shell calls;
- tests;
- documentation.

A safe Make wrapper does not excuse a weaker direct supported script path.

## Secrets and key custody

The repository uses SOPS + Age.

Keep distinct:

- the server's operational Age private key;
- an offline recovery Age private key;
- an Age public recipient;
- SOPS recipient policy;
- backup encryption recipients;
- emergency backup passphrase protection.

The optional offline recovery private key must not be persisted to the server.

Never:

- commit plaintext production secrets;
- print secret values in normal logs;
- expose secrets in command arguments when avoidable;
- persist an offline recovery private key;
- weaken root-owned key permissions;
- copy private key material into ordinary diagnostics;
- present a key-preservation or re-encryption failure as success.

Temporary secret and private-key material must use restrictive permissions and reliable cleanup.

When changing secrets behavior, inspect `secrets-schema.yaml`, schema helpers, setup/edit/rotate paths, runtime materialization, recovery, backup inclusion rules, and generated documentation as applicable.

## Operation guards and concurrency

Conflicting mutating workflows use the shared operation-guard architecture owned by `lib/operations.sh`.

Kernel `flock` state is authoritative. Operation metadata is descriptive and operator-facing.

Preserve the existing design unless the task explicitly changes it:

- global serialization where required;
- operation-specific locks where justified;
- inherited foreground lock support;
- verified owner identity;
- conservative stale metadata handling;
- controlled TERM-before-KILL behavior;
- refusal to automatically terminate package-manager work;
- exit `75` where the owning non-interactive/systemd contract uses it for expected contention.

Do not infer an active operation from lock-file existence alone.

`--force` may bypass an explicit confirmation where documented. It must not silently bypass the shared operation guard.

Read-only paths should not take the global mutating lock without a demonstrated resource conflict.

Do not replace `flock` with a database, daemon, Redis, or distributed lock service.

## Operator CLI and Make contract

Public shell commands and advertised Make targets are operator APIs.

For a supported command:

- help text must match executable grammar;
- canonical syntax must be obvious;
- unknown arguments must fail clearly;
- missing option values must be detected before `shift`;
- options must apply only to the subcommands that own them;
- privilege requirements must be truthful;
- timeout, EOF, and SSH-disconnect behavior must fail safely;
- success text must match the actual exit state.

Interactive safety prompts should follow the repository's current explicit yes/no convention. Do not introduce ambiguous `y/N` or `Y/n` prompts into operator safety paths.

When changing a parser, subcommand, flag, or Make target, search every caller. At minimum consider:

- `Makefile`;
- `dashboard.sh`;
- top-level dispatchers;
- `utilities/`;
- `systemd/`;
- `.github/workflows/`;
- tests;
- generated command reference;
- hand-maintained docs.

The Makefile is primarily an operator/day-2 interface. It is not the permanent test inventory owner.

## systemd and installed runtime

Managed automation uses systemd. Do not add a second scheduler.

Repository scripts and installed runtime copies can diverge. When changing a path, command grammar, runtime directory, library, operation status, or exit code used by automation, inspect both:

- `systemd/`;
- `utilities/setup-systemd.sh`.

Also inspect any runtime-copy/install validation owned by the systemd setup path.

A Git checkout update does not automatically prove that root-owned installed copies under the managed runtime path have been activated on an existing host.

Expected contention must not generate a false failure incident. Real failures must not be converted into clean contention success.

Keep service/timer templates, installed artifacts, failure notification, and validation semantics aligned.

## Backup, restore, and disaster recovery

The repository intentionally has three backup tiers:

```text
db
full
emergency
```

Do not collapse them into one generic backup type.

Treat backup, restore, and recovery as high-risk production workflows.

Backup success must reflect actual verification state. A failed required verification must not be presented as a successful backup. Offsite sync not requested is different from offsite sync requested but skipped or failed.

Retention must preserve the repository's current recovery-point safety contract. Do not make cleanup more aggressive without tracing local and remote selection, sidecars, restore discovery, and failure behavior.

Restore and recovery changes require end-to-end reasoning across:

- preflight;
- archive selection;
- decryption and passphrase handling;
- pre-restore snapshot;
- service stop;
- SQLite/WAL handling;
- staging and extraction;
- permission repair;
- secrets and key handling;
- promotion/commit boundary;
- rollback;
- start policy;
- service startup;
- `/alive` verification;
- final operator guidance.

An incomplete restore or recovery must not be presented as success.

Prefer a local transaction boundary in the owning workflow. Do not add a generic transaction framework.

Preserve the operator-controlled disaster-recovery startup policy unless the task explicitly changes it.

## Storage

Storage behavior must remain provider-neutral.

The repository supports boot-volume state and an explicitly configured attached data/block volume. Use current configuration/default owners rather than hard-coding remembered paths.

The `.vw-data-volume` sentinel is a project ownership and safety contract.

Ambiguous mounted-volume ownership must fail closed before destructive format, mount, fstab, migration, or cleanup behavior.

Do not assume provider-specific device names or one universal `/dev/sdX`/`/dev/vdX` path. Prefer operator-supplied or stable device paths such as `/dev/disk/by-id/...` where appropriate.

Do not build a generic storage orchestration layer.

## Tests

The canonical permanent Bash test entry point is:

```bash
./tests/run-tests.sh all
```

`tests/run-tests.sh` owns the permanent `tests/test-*.sh` inventory.

Do not create:

- one permanent test file per issue;
- one test file per PR;
- one test file per audit finding;
- a second permanent test inventory in Make or workflow YAML.

Add coverage to the closest production-domain test whenever practical.

Distinguish clearly between:

- real behavioral execution;
- mocked behavior;
- structural/static assertions;
- string/grep assertions.

A structural assertion is appropriate when source structure is the contract. For high-risk runtime control flow, prefer behavioral or focused mocked-behavior coverage where practical.

Important domains include architecture, privilege/security, permissions, configuration, secrets, operation guards, lifecycle, systemd, email, storage, backup, restore/recovery, operator UI, CrowdSec, and uninstall/reset behavior.

Do not preserve weak duplicate tests solely for assertion-count parity.

## CI and workflows

GitHub Actions should validate current repository contracts, not preserve historical agent/audit machinery.

Permanent workflow rules:

- keep the workflow set small;
- workflows may call the canonical test runner but must not duplicate its individual test list;
- strict ShellCheck may run independently;
- generated documentation and focused repository invariants may have dedicated checks where they provide real value;
- use least-privilege workflow permissions;
- pin externally downloaded tools or verify their integrity where the repository contract requires reproducibility;
- do not keep one-shot report appenders, temporary diagnostics, or PR-specific repair workflows after their purpose has ended;
- do not grant `contents: write` to a normal validation workflow without a current need.

When changing CI, inspect path filters so a contract-changing file cannot silently bypass the relevant check.

CI is not a substitute for production-host acceptance where the behavior depends on real systemd, apt/dpkg, block devices, host firewall behavior, or installed runtime activation.

## Documentation and generated files

Documentation must match the supported normal production path and current executable grammar.

Do not rewrite broad documentation for small wording preferences. Update materially incorrect commands, paths, support claims, privilege requirements, safety procedures, recovery steps, key-custody instructions, backup semantics, or storage behavior.

Generated documentation must be regenerated through the repository's established generator. Do not hand-edit generated output when a source/generator owns it.

When a change affects a public command, inspect the command reference generator and current docs before deciding documentation is unaffected.

Historical reports under `reports/` are evidence and decision history. Do not treat them as live implementation specifications without re-validating the current branch.

## Audit and review discipline

For audit or review work:

1. Record the exact branch/ref and, when available, commit SHA.
2. Inspect current executable code first.
3. Derive the current contract from code and canonical configuration.
4. Inventory supported entry points and automation callers.
5. Trace realistic end-to-end production paths.
6. Compare callers, callees, tests, systemd, Make, workflows, and docs.
7. Use prior reports only to understand history and accepted decisions.
8. Reproduce or strongly trace a defect before reporting it as confirmed.
9. Distinguish a code defect from missing automated coverage and from production-host validation needs.
10. Accept a clean review when the evidence is clean.

Do not invent findings to justify an audit.

For report-only tasks, do not modify production code unless the task explicitly authorizes implementation.

## Git and repository hygiene

Follow the task's branch and delivery instructions exactly.

Unless the task explicitly authorizes direct writes to a protected or long-running branch, prefer a focused branch and pull request.

Do not:

- force-push or rewrite shared history without explicit instruction;
- merge a PR unless explicitly asked;
- delete unrelated branches;
- commit local secrets, `.env`, runtime keys, backup archives, or diagnostic secret material;
- include unrelated formatting churn;
- leave temporary workflow files or diagnostic scripts behind;
- modify `AGENTS.md` to encode one task's acceptance criteria.

Commit messages should describe the repository change, not the agent session.

Before completion, inspect the final changed-file set and ensure every file is intentional.

## Validation guidance

Use the lowest-cost validation that meaningfully exercises the changed contract, then add stronger validation where the risk requires it.

Common checks include:

```bash
git diff --check
```

```bash
find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 -n 1 bash -n
```

```bash
find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 shellcheck -x --severity=warning
```

```bash
./tests/run-tests.sh all
```

```bash
docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

Run focused domain tests in addition to the canonical suite when the affected behavior is high risk.

Do not run destructive production-host operations merely to satisfy a generic checklist.

When local execution is intentionally skipped because the task delegates validation to GitHub Actions, say so clearly and rely only on the exact CI results that actually ran.

## Completion standard

A change is complete when:

- the requested scope is addressed;
- the implementation uses the current canonical architecture;
- affected callers and public surfaces are consistent;
- security, privilege, concurrency, and failure semantics remain truthful;
- focused regression coverage exists where appropriate;
- documentation or generated output is updated when materially affected;
- obsolete temporary artifacts introduced by the work are removed;
- the final diff contains only intentional changes;
- validation results and limitations are reported honestly.

The goal is not the largest or cleverest change.

The goal is a small, high-quality, production-safe change that a junior operator can understand and the next maintainer can verify.
