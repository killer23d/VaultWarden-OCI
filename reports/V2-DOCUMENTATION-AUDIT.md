# VaultWarden-OCI V2 Documentation Audit

Date: 2026-08-18
Revision: consolidated with the authoritative Codex contract and later SOPS/Age, rclone, and notification decisions.

> **Agent-execution precedence:** `reports/V2-CODEX-PROMPTS.md` is authoritative. This file defines the intended documentation model and supporting rationale. If it conflicts with the prompt contract, the prompt contract wins and this file should be corrected.

## Executive conclusion

V1 documentation is unusually thorough, but its size mirrors the implementation complexity. It documents many public scripts, Make targets, backup tiers, migration paths, email queue behaviors, dashboard flows, synchronization rules, and compatibility surfaces.

V2 should reduce the product surface first and then document the smaller product clearly. Documentation must not preserve a removed V1 mechanism merely because it was previously documented.

## V2 documentation set

Target six operator/developer documents:

1. `README.md`
2. `docs/INSTALL.md`
3. `docs/OPERATIONS.md`
4. `docs/SECURITY.md`
5. `docs/RECOVERY.md`
6. `docs/DEVELOPMENT.md`

Use `vwctl --help` as the executable command reference. Do not regenerate a large command-reference document that must be kept in sync with every parser change.

Architecture decisions may live in a small ADR directory/index. Reports under `reports/` are design/audit inputs, not the normal operator manual.

## Agent-facing documentation

Root `AGENTS.md` should remain concise and durable. It should:

- state that `reports/V2-CODEX-PROMPTS.md` is the authoritative V2 agent execution contract;
- direct agents to the applicable phase/corrective prompt;
- state the greenfield/no-V1-compatibility boundary;
- summarize the Python/Bash ownership boundary;
- link the small product-boundary/ADR set;
- warn against speculative frameworks and later-phase implementation.

It should **not** copy the full architecture, test matrix, command inventory, or operational runbook. Duplicating the prompt contract in `AGENTS.md` would create another drift source.

## README.md

Keep README focused on:

- what V2 is and is not;
- supported Ubuntu/architectures;
- Cloudflare-first/CrowdSec security posture;
- high-level Vaultwarden+Caddy architecture;
- links to install/operations/security/recovery/development docs;
- minimal quick-start pointer.

Do not turn README into the full runbook.

## docs/INSTALL.md

Document the golden path only:

- Ubuntu 24.04 prerequisite;
- amd64/arm64 support;
- cloud/provider firewall prerequisites without provider-specific runtime APIs;
- domain/Cloudflare prerequisites;
- installed filesystem layout;
- SOPS + Age operational identity and offline recovery material setup;
- configuration setup;
- Vaultwarden direct SMTP setup;
- operational notification HTTPS API + SMTP fallback configuration after a concrete provider is selected;
- rclone configuration for offsite recovery;
- install/start/doctor verification.

Do not include V1 upgrade/migration/import procedures.

## docs/OPERATIONS.md

Document a small set of normal operator tasks through `vwctl`:

- start/stop/restart/status/logs;
- doctor and interpretation of stable check states;
- config show/validate/edit;
- secret edit/rotation workflow as actually implemented;
- manual backup and offsite status;
- explicit rclone retention/pruning behavior;
- update check/apply;
- systemd timer inspection;
- notification delivery status/diagnostics.

For operational notifications, explain the intended flow clearly:

`HTTPS API primary -> bounded retry -> authenticated SMTP fallback only for transient delivery-path failures`

Document that configuration/auth/permanent request errors and certificate/hostname validation failures remain visible. Do not imply SMTP always masks API failure.

Document that there is no local durable mail queue in beta. If both transports fail, the operator sees failure state through status/doctor rather than inspecting a Postfix queue.

## docs/SECURITY.md

Explain security boundaries, not implementation trivia:

- Cloudflare-first origin exposure model;
- Docker-published port/firewall path and fail-closed behavior;
- CrowdSec host/edge roles;
- container hardening;
- SOPS + Age secret-at-rest design;
- operational vs offline recovery Age identities;
- decrypted runtime secret lifetime/location;
- direct SMTP TLS requirements;
- HTTPS notification API TLS validation and secret handling;
- why API credentials/SMTP passwords must not appear in argv/logs/debug transcripts;
- rclone credential protection model;
- backup encryption/recovery trust model;
- production version pinning and `--use-latest` restrictions.

Do not document multiple unsupported firewall/provider abstractions.

## docs/RECOVERY.md

Document one recovery product, not V1's multiple public tiers.

Cover:

- what one V2 recovery point contains/excludes;
- offline recovery material and why the operational Age private key is excluded from normal backup artifacts;
- local verification before publication;
- offsite publication sequence:
  `create -> verify local -> rclone copy/copyto -> verify remote -> success`;
- retention/pruning as a separate explicit deletion operation;
- restore preflight/staging/promotion/health behavior;
- remote listing/download/staging through rclone;
- disaster recovery procedure;
- periodic restore drill guidance.

Explicitly state that normal publication does not use destructive `rclone sync` semantics that can delete remote recovery points simply because local files disappeared.

No V1 archive reader/migration documentation belongs in V2.

## docs/DEVELOPMENT.md

Document only what developers/agents need:

- `v2` branch workflow;
- `reports/V2-CODEX-PROMPTS.md` as authoritative agent execution contract;
- phase-by-phase implementation rule;
- Python 3.12 stdlib-first/Bash-minimal boundary;
- pytest/ruff/ShellCheck usage;
- three-layer test strategy;
- small permanent PR CI vs release host acceptance;
- how to run focused validation;
- release/version pinning and dev/test-only `--use-latest`;
- rule against provider/plugin/framework creation without an explicit architecture change.

## Documentation deletion/consolidation targets

Do not carry forward V1 documents whose product surfaces disappear, including documentation centered on:

- V1 data/state/archive migration;
- three public backup tiers;
- Postfix queue inspection/mutation;
- dashboard/TUI operation;
- repository-to-installed-runtime synchronization;
- giant Make/operator command inventories;
- V1 compatibility aliases;
- exhaustive generated command references.

Useful security/recovery reasoning should be rewritten into the six V2 documents rather than preserved as a compatibility manual.

## Drift control

Prefer executable/stable interfaces over grep-heavy documentation CI:

- `vwctl --help` is command reference truth;
- stable doctor JSON/check IDs are machine-readable diagnostic truth;
- one `versions.toml` is version truth;
- one `config.toml` is non-secret runtime config truth;
- `reports/V2-CODEX-PROMPTS.md` is agent execution truth.

Documentation checks may verify links/basic consistency, but should not recreate a large policy engine that greps exact prose or duplicates product configuration.

## Documentation acceptance criteria

Before V2 beta, a junior admin should be able to answer from the docs:

- how do I install and verify it?
- where is configuration stored?
- how are secrets protected and recovered offline?
- how do I check service/edge/notification health?
- what happens if the HTTPS notification API is unavailable?
- how do I create, verify, publish, list, download, prune, and restore recovery points with rclone?
- how do I update safely?
- what does V2 intentionally not support?

If answering those questions requires reading implementation source or a V1 compatibility document, the V2 documentation set is incomplete.