# AGENTS.md — VaultWarden-OCI V2 repository map

## Start here

VaultWarden-OCI V2 is a **greenfield fresh-install product**, not a compatibility refactor of V1. The target is a small deployment of roughly 10 users operated by a junior administrator on Ubuntu 24.04 LTS Noble, tested on amd64 and arm64.

V1 remains useful as a **security and behavioral reference only**. Do not preserve V1 project state, backup formats, migration paths, command aliases, runtime layout, Postfix/queue machinery, dashboard behavior, test architecture, or implementation shape unless a current V2 decision explicitly requires the underlying property.

For each task, use this order of authority:

1. explicit human instructions for the task;
2. the complete standalone phase/corrective prompt in `reports/V2-CODEX-PROMPTS.md`;
3. the V2 product/decision documents listed below;
4. this file as a repository map.

If a supporting document conflicts with the pasted task prompt, report the conflict rather than silently changing architecture. Ordinary phase/corrective work must not edit `reports/V2-CODEX-PROMPTS.md`.

## V2 documents

Read the documents relevant to the task before implementation:

- `reports/V2-CODEX-PROMPTS.md` — authoritative standalone implementation prompts and phase boundaries.
- `docs/PROJECT-BOUNDARY.md` — concise supported V2 product boundary.
- `docs/V2-DECISIONS.md` — durable Phase 0 implementation decisions and fixed authorities.
- `reports/V2-ARCHITECTURE-PROPOSAL.md` — target architecture and rationale.
- `reports/V2-AUDIT.md` — evidence for the greenfield reset and V1 lessons.
- `reports/V2-TEST-STRATEGY.md` — bounded three-layer testing model.
- `reports/V2-REVIEW-PROMPTS.md` — reviewer utility only; not an implementation authority.

## Implementation ownership

Use Python 3.12 standard-library-first for structured logic: CLI parsing, TOML/config/version handling, validation, subprocess orchestration, locking, diagnostics, secrets orchestration, notification classification, recovery metadata, rclone orchestration, and edge policy.

Use Bash only for the smallest bootstrap, host/container glue, or other cases where shell is materially simpler. Do not let Bash grow into the owner of structured configuration, state machines, retry policy, complex locking, or broad orchestration.

The public operator surface is `vwctl`. The installed **operator-editable** non-secret config authority is `/etc/vaultwarden-oci/config.toml`; the source-controlled version authority is `versions.toml`. Source-controlled immutable release metadata such as the Phase 6 `email-providers.toml` catalog is not a second operator-editable config authority. Do not create alternate editable authorities.

## Design discipline

Prefer the smallest explicit implementation that satisfies the current phase. Do not add speculative frameworks, dynamic plugin/provider registries, ORMs, daemons, databases, event buses, workflow engines, generic transaction frameworks, distributed locks, HA/Kubernetes/Swarm abstractions, or cloud/storage/notification/firewall abstraction layers without an explicit product decision.

Prefer fewer cohesive first-party files when responsibilities remain clear. Before adding a file, ask whether an existing owner can absorb the behavior cleanly. Avoid one-function modules, one-action wrapper scripts, duplicate config fragments, empty placeholders, and future-facing extension files. File reduction is a preference, not a quota; do not create giant mixed-responsibility files to game it. A deliberate closed metadata catalog can be appropriate when it removes duplicated provider constants/templates without creating runtime extensibility.

Do not implement later phases opportunistically. Report useful out-of-scope ideas instead.

## Testing

V2 uses only three permanent validation layers:

1. focused unit tests;
2. small integration tests;
3. disposable real-host release acceptance.

Tests protect security, availability, recoverability, and operator truthfulness. Do not port V1's custom runner/inventory or add private source-string/order assertions, private-function extraction, prose freezing, duplicated state machines, or a coverage-percentage gate.

## Working rules

Before editing, inspect the current branch/ref and the existing owner of the behavior. Keep each change bounded to the assigned phase or corrective task. Preserve secret redaction, fail-closed security boundaries, truthful success/failure reporting, and recoverability.

Run only validation proportional to the change and report exactly what ran and what did not. Never claim host, architecture, provider, CI, or destructive validation that was not actually performed.
