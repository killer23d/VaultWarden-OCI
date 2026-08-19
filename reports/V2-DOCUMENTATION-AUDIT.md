# VaultWarden-OCI V2 Documentation Audit

Date: 2026-08-18

## Executive assessment

V1 documentation is unusually thorough for a small-team infrastructure project. Its weakness is not missing documentation; it is that the documentation surface mirrors the implementation surface too closely.

A junior administrator currently has to navigate separate material for deployment, architecture, configuration, operations, security, backups, disaster recovery, bootstrap-key recovery, runtime permissions, credential handoffs, CrowdSec, email, migration, volume migration, scripts, host acceptance, troubleshooting, API behavior, customization, a runbook, and a generated command reference.

That is appropriate documentation for a complex platform, but V2 should be a simpler appliance.

The V2 documentation strategy should therefore be **subtractive**: reduce implementation concepts, then document fewer stable workflows.

---

# 1. Current strengths

## Clear product boundary

The current project explicitly states:

- Ubuntu 24.04 LTS Noble;
- amd64/arm64;
- Cloudflare-first normal path;
- Caddy;
- CrowdSec;
- SOPS/Age;
- rclone/offsite backup;
- systemd automation;
- cloud-provider-neutral runtime.

It also clearly places `--use-latest` outside the normal production/golden path.

This clarity should be preserved in V2.

## Security documentation is substantive

The security documentation describes real trust boundaries rather than presenting a generic hardening checklist. It explains:

- Cloudflare-origin restrictions;
- Docker packet-filter interaction;
- CrowdSec edge enforcement;
- root-operated lifecycle;
- secret lifetimes;
- recovery-key custody;
- backup verification;
- restore destructive boundaries;
- runtime permissions;
- systemd/container hardening.

V2 should retain this style but document a smaller architecture.

## Recovery is treated as an operator workflow

Backup/recovery documentation is detailed enough that the project clearly considers restore correctness part of the product. Preserve the recovery-first attitude.

## Documentation drift is already recognized

The repository contains a documentation-drift workflow and generated command-reference tooling. This is a good engineering instinct. V2 should retain automated drift detection but reduce the amount of generated operator material.

---

# 2. Main documentation problem: fragmentation

The current documentation tree includes at least:

- `README.md`
- `RUNBOOK.md`
- `docs/ADVANCED-CUSTOMIZATION.md`
- `docs/API.md`
- `docs/ARCHITECTURE.md`
- `docs/BACKUP-RESTORE.md`
- `docs/BOOTSTRAP_KEY_RECOVERY.md`
- `docs/COMMAND-REFERENCE.md`
- `docs/CONFIGURATION.md`
- `docs/CROWDSEC.md`
- `docs/DEPLOYMENT.md`
- `docs/DISASTER-RECOVERY.md`
- `docs/EMAIL.md`
- `docs/HOST-ACCEPTANCE.md`
- `docs/MIGRATION.md`
- `docs/OPERATIONS.md`
- `docs/PROJECT-BOUNDARY.md`
- `docs/RECOVERY-CARD.md`
- `docs/RESTORE-RUNTIME-PERMISSIONS.md`
- `docs/SCRIPTS.md`
- `docs/SECRETS-SCHEMA.md`
- `docs/SECURE-CREDENTIAL-HANDOFFS.md`
- `docs/SECURITY.md`
- `docs/TROUBLESHOOTING.md`
- `docs/VOLUME-MIGRATION.md`
- `utilities/README.md`
- `tests/README.md`
- `AGENTS.md`
- `CHANGELOG.md`

The issue is not simply the count. Several topics represent separate operator concepts that V2 can eliminate entirely.

---

# 3. Documents that should not be ported as V2 operator docs

## `MIGRATION.md`

Do not port. V2 is a fresh-start release by product decision.

If migration from another password manager is useful, link to upstream Vaultwarden/Bitwarden import guidance rather than building project-state migration machinery.

## `VOLUME-MIGRATION.md`

Do not port as a first-class V2 document. A greenfield install should choose its state root before deployment. If later movement of a data volume is required, document it as an advanced maintenance recipe only after a real need appears.

## `RESTORE-RUNTIME-PERMISSIONS.md`

Do not keep as a standalone operator document. Correct permission repair should be owned by `vwctl restore` / `vwctl doctor`. The exact permission contract belongs in developer/security documentation.

## `SCRIPTS.md`

Do not port as operator documentation. V2 should have one public CLI; internal module ownership belongs in `DEVELOPMENT.md`.

## Giant `COMMAND-REFERENCE.md`

Do not make this a primary document. Exact CLI grammar should be generated from `vwctl --help` and optionally rendered to a compact reference page.

## `HOST-ACCEPTANCE.md`

Fold normal checks into `vwctl doctor` and the release test contract. Operators should not manually reproduce a large acceptance procedure for routine installs.

## Separate secure-handoff documents

`BOOTSTRAP_KEY_RECOVERY.md`, `SECURE-CREDENTIAL-HANDOFFS.md`, and `RECOVERY-CARD.md` can be consolidated into the V2 recovery/security model. The offline key/recovery kit still matters; it does not require several normal-path documents.

---

# 4. Proposed V2 documentation set

## `README.md`

Audience: evaluator/new administrator.

Target length: concise.

Contents:

1. What VaultWarden-OCI V2 is.
2. Supported boundary.
3. Architecture diagram.
4. Security model in five bullets.
5. Requirements.
6. Three-command quick start or link to install.
7. Core `vwctl` commands.
8. Links to the five detailed docs.

Avoid operational edge cases here.

## `docs/INSTALL.md`

Audience: junior admin performing first deployment.

Golden path only at the top:

1. Prepare Ubuntu 24.04 host.
2. Configure provider firewall/SSH prerequisites.
3. Prepare Cloudflare domain/token.
4. Run installer.
5. Edit config/secrets.
6. Start.
7. Run `vwctl doctor`.
8. Confirm backup destination.
9. Export offline recovery material.

Advanced direct mode goes at the bottom or in development/advanced section.

Installation docs should never require reading architecture docs to complete normal setup.

## `docs/OPERATIONS.md`

Audience: day-to-day junior admin.

Task-oriented headings:

- Check status.
- Run diagnostics.
- Restart safely.
- View logs.
- Edit configuration.
- Rotate a secret.
- Test email.
- Check CrowdSec/edge status.
- Check backups.
- Update V2.
- Handle disk pressure.
- Handle a failed timer/service.

Each task should use `vwctl`, not internal helpers.

## `docs/SECURITY.md`

Audience: administrator + reviewer.

Contents:

- threat model and non-goals;
- trust boundaries;
- Cloudflare mode vs direct mode;
- host firewall/Docker assumption;
- CrowdSec purpose;
- container privilege model;
- secrets and Age key custody;
- backup/recovery trust model;
- update/supply-chain policy;
- `--use-latest` explicitly excluded from production guidance.

Do not document removed V1 mechanisms.

## `docs/RECOVERY.md`

Audience: operator under stress.

Contents:

- what the normal backup contains;
- where backups live;
- where offline recovery material must be stored;
- restore on same host;
- rebuild on replacement Ubuntu 24.04 host;
- verification after restore;
- periodic recovery drill checklist.

This document should be printable/useful without following links during an incident.

## `docs/DEVELOPMENT.md`

Audience: maintainers/contributors.

Contents:

- source layout;
- architecture rationale;
- tests;
- build/install dev workflow;
- version manifest;
- how pins are updated;
- `--use-latest` behavior;
- release process;
- security invariants asserted by tests;
- OCI A1 Flex reference testing.

Implementation details belong here rather than in operator docs.

---

# 5. `--use-latest` documentation contract

The flag should appear prominently in `DEVELOPMENT.md`, not in the production quick-start examples.

Recommended language:

> `--use-latest` is a compatibility/testing mode. It resolves the newest compatible upstream component releases for the current test invocation and records the exact resolved set. It is not the supported production version policy. Production installs consume the version pins shipped by the V2 release.

The command should print the same warning so documentation and runtime agree.

Documentation should explain how the latest compatibility CI probe uses this flag without modifying production pins.

---

# 6. Cloud and CPU wording

Avoid vague claims such as "runs everywhere" or "CPU agnostic."

Recommended support wording:

> V2 is cloud-provider neutral and contains no required OCI/AWS/Azure/GCP runtime integration. Releases are tested on Ubuntu 24.04 LTS for amd64 and arm64. OCI A1 Flex is maintained as an ARM64 reference deployment.

This is precise, testable, and still communicates portability.

---

# 7. OCI documentation

Do not make OCI part of the main install instructions.

Provide a small reference section/appendix in `INSTALL.md` or a later `docs/REFERENCE-OCI.md` only if needed. It should cover provider-side prerequisites without changing runtime behavior:

- Ubuntu 24.04 ARM64 instance;
- A1 Flex sizing example;
- NSG/security list ingress;
- block-volume stable device identification;
- Cloudflare DNS/proxy setup.

The same structure can later support AWS/Azure/GCP examples without branching the installer.

---

# 8. Documentation style guide for junior admins

Every normal task should answer, in order:

1. **When would I do this?**
2. **What command do I run?**
3. **What does success look like?**
4. **What do I run if it fails?**

Prefer:

```text
sudo vwctl doctor
```

Then show a short representative result and remediation.

Avoid sending the operator through chains such as:

```text
README -> RUNBOOK -> ARCHITECTURE -> SCRIPT REFERENCE -> helper script
```

for a routine task.

---

# 9. Generated documentation and drift control

Keep automated drift prevention, but constrain what is generated.

Generate/check:

- CLI reference from `vwctl` command definitions;
- configuration key reference from the typed schema;
- version table from `versions.yaml`;
- links;
- example configuration validity;
- architecture/support statements against constants/tests where feasible.

Do not generate narrative operating procedures. Human-written task workflows should remain reviewable prose.

CI should fail when:

- documented public commands do not exist;
- example config contains unknown/invalid keys;
- docs claim a different supported Ubuntu/architecture set than code;
- docs contain stale production version numbers that should come from generated references.

---

# 10. Troubleshooting strategy

A large troubleshooting encyclopedia should not be the first diagnostic layer.

Use this order:

1. `vwctl doctor` identifies subsystem and remediation.
2. `docs/OPERATIONS.md` gives common fixes.
3. A compact troubleshooting section covers known non-obvious cases.
4. GitHub issues/discussions capture rare incidents until they justify stable documentation.

This avoids permanently documenting implementation accidents that disappear during V2 evolution.

---

# 11. Release documentation

For V2 releases:

- `CHANGELOG.md` should describe operator-visible/security-impacting changes, not internal refactor detail;
- release notes should state the supported Ubuntu/architectures and version-policy behavior;
- because V2 is fresh-start, release notes must clearly state that it is not an in-place V1 upgrade/migration path;
- future V2.x compatibility/migration promises should be stated only after the new state schema is stable.

---

# 12. Documentation acceptance checklist

Before V2.0, test the docs with a person who did not implement the feature.

They should be able to answer without source-code reading:

- Which Ubuntu version is supported?
- Which CPU architectures are tested?
- Is OCI required?
- Which public ports are expected?
- Where is configuration?
- Where are secrets?
- How do I run a health check?
- How do I diagnose a failure?
- How do I update?
- What does `--use-latest` mean?
- How do I make a backup?
- What do I need if the server is lost?
- How do I restore on a new host?
- Where do I find CrowdSec/Cloudflare status?

If the answer requires understanding multiple internal scripts, the V2 interface or documentation is still too complex.

---

# Final documentation recommendation

V1 proves that the project can document complex behavior carefully. V2 should use that capability to document a **smaller product**, not to preserve every historical concept.

The documentation objective is:

> One obvious install path, one obvious daily operations guide, one security model, one recovery guide, and one maintainer guide.

Reducing the documentation surface is not a loss of rigor when the underlying architecture is also reduced. It is a measurable sign that V2 succeeded in becoming easier to operate.