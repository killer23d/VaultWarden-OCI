# VaultWarden-OCI V2 Documentation Audit

Date: 2026-08-18
Revision: post-rescan documentation model.

## Executive conclusion

V1 documentation is unusually thorough, but its size mirrors the implementation complexity. The current repository documents many public scripts, Make targets, backup tiers, recovery modes, storage migration, advanced email paths, dashboard behavior, systemd synchronization, CrowdSec internals and compatibility rules.

For V2, the documentation objective is not to rewrite all V1 documents. It is to **delete the need for most of them** by shrinking the product surface.

A junior administrator should have one obvious install path, one command namespace, one configuration file, one diagnostic command and one recovery procedure.

---

# 1. Problems identified in V1

## DOC-01 — documentation is an API map for too many APIs

V1 has operator behavior spread across:

- `setup.sh`;
- `Makefile`;
- top-level wrapper scripts;
- `maintenance.sh`;
- `edit-secrets.sh`;
- many `utilities/*.sh` entrypoints;
- dashboard menu actions;
- systemd-installed copies;
- generated command reference.

The documentation has to explain and keep all of these aligned.

### V2 decision

One operator API: `vwctl`.

Documentation should explain task-oriented commands rather than script ownership.

## DOC-02 — generated exhaustive command reference is a symptom

`docs/COMMAND-REFERENCE.md` is large because the executable command surface is large. Maintaining a generator and CI drift checks for such a reference adds another source/test/doc cycle.

### V2 decision

Do not generate an exhaustive command-reference document for beta.

`vwctl --help` and subcommand help are the exact command grammar. Handwritten docs describe workflows and link to `--help` for flags.

## DOC-03 — implementation internals leak into junior-admin docs

V1 necessarily explains installed-runtime copies, repository/runtime split-brain, multiple configuration authorities, three backup tiers, operation guards, queue IDs and complex restore key distinctions.

These are difficult to simplify editorially because they are real implementation contracts.

### V2 decision

Simplify the implementation first. Documentation then describes:

- one config path;
- one secrets path;
- one backup command;
- one restore command;
- one status/doctor interface;
- a small number of systemd timers.

## DOC-04 — V1 migration documentation should not be carried forward

V2 is explicitly fresh-install only.

### V2 decision

Do not create V2 migration or volume-migration guides. If operators need to move V2 state between disks/hosts, document backup -> fresh install -> restore rather than a stateful migration subsystem.

## DOC-05 — agent instructions are documentation too

Current `AGENTS.md` encodes V1 architectural commitments. If left unchanged on the V2 development branch, it will push coding agents toward retaining V1 mechanisms.

### V2 decision

V2 `AGENTS.md` is a critical architecture artifact. It must be rewritten before runtime implementation and kept concise enough that constraints are obvious.

It should contain:

- product boundary;
- security invariants;
- Python/Bash boundary;
- simplicity/non-goals;
- test policy;
- phase/scope discipline;
- rule that V1 is reference behavior, not compatibility API.

It should **not** become a running audit log or copy every implementation detail.

---

# 2. Proposed V2 documentation set

Keep the permanent operator documentation intentionally small.

## `README.md`

Purpose:

- what the project is;
- supported host/CPU matrix;
- two-minute architecture overview;
- prerequisites;
- link to installation;
- high-level security model;
- current release status.

Target: concise enough to read before choosing the project.

## `docs/INSTALL.md`

One golden path only:

1. prepare Ubuntu 24.04 host;
2. prepare Cloudflare DNS/token and provider ingress prerequisites;
3. install V2;
4. edit/validate config;
5. configure secrets;
6. start;
7. run `vwctl doctor`;
8. create recovery kit and first backup;
9. enable/check timers.

Do not mix alternate edge modes into this guide.

## `docs/OPERATIONS.md`

Day-2 junior-admin tasks:

- status;
- doctor;
- logs;
- start/stop/restart;
- edit config;
- rotate secrets;
- backup;
- update;
- timers;
- common symptom -> command mapping.

This replaces a large part of V1's Runbook + Operations + Scripts + command reference surface.

## `docs/SECURITY.md`

Describe security properties and trust boundaries, not implementation archaeology:

- Cloudflare -> host ingress -> Caddy -> Vaultwarden;
- CrowdSec edge/host roles;
- secret custody;
- root mutation model;
- container hardening;
- direct SMTP trust boundary;
- backup/recovery identity separation;
- what the project does not protect against.

Keep exact credential scopes/paths where an operator needs them.

## `docs/RECOVERY.md`

One recovery model:

- what the normal encrypted recovery point contains;
- what the offline recovery kit contains;
- how to verify both before an incident;
- fresh-host recovery steps;
- start policy;
- post-restore doctor check.

Do not document V1 backup tiers or formats.

## `docs/DEVELOPMENT.md`

Maintainer-only material:

- source layout;
- Python/Bash boundary;
- local test/lint commands;
- versions manifest;
- `--use-latest` development policy;
- disposable host acceptance process;
- how to add a supported config field or doctor check;
- explicit instruction not to add framework/compatibility layers without an ADR.

---

# 3. Documentation that should not exist in V2 beta

Do not recreate separate permanent documents for:

- script ownership/reference;
- generated command grammar;
- V1 migration;
- volume migration;
- three backup tiers;
- Postfix queue administration;
- dashboard menus;
- alternate email API providers;
- multiple TLS modes;
- multiple firewall backends;
- installed-copy synchronization;
- V1 bootstrap key compatibility;
- large advanced-customization catalogs.

If an advanced capability is not in the beta product, there should not be a placeholder guide promising it.

---

# 4. Documentation style for a junior admin

Every operator procedure should answer four questions:

1. **Why am I doing this?**
2. **What command do I run?**
3. **What does success look like?**
4. **What command diagnoses failure?**

Prefer examples such as:

```text
sudo vwctl backup
sudo vwctl doctor
```

over multi-layer implementation explanations.

For destructive operations, explicitly state:

- what changes;
- what does not change;
- what prerequisite/recovery point is required;
- what failure leaves behind;
- whether services are started afterward.

Avoid requiring the operator to know which Python module, shell script or systemd helper owns the behavior.

---

# 5. `vwctl doctor` changes the troubleshooting model

A strong diagnostic interface lets documentation become much smaller.

Troubleshooting should primarily map symptoms to stable diagnostic check IDs:

```text
Problem: site unavailable
Run: sudo vwctl doctor
Relevant checks: docker.*, caddy.*, vaultwarden.alive, firewall.*, cloudflare.*
```

The JSON form can support issue reports and automated acceptance without requiring exact human output to remain frozen.

Avoid creating a separate troubleshooting command for every subsystem.

---

# 6. Version/update documentation

Production docs should never instruct operators to use floating latest versions.

Document:

```text
vwctl versions
vwctl update check
vwctl update apply
```

`--use-latest` belongs only in `DEVELOPMENT.md` and should be labeled clearly as a test/development override that resolves and records exact versions for that run.

This prevents the testing escape hatch from appearing as a production recommendation.

---

# 7. Cloud/provider neutrality documentation

Describe the runtime as:

> Ubuntu 24.04 LTS on tested amd64 or arm64 hosts. The runtime is cloud-provider neutral; OCI A1 Flex is a reference deployment, not a dependency.

The installation guide should describe provider firewall/security-group work generically, with optional short provider examples where useful. Do not introduce provider API automation into core docs merely to make examples uniform.

---

# 8. Documentation tests

Documentation validation should be minimal.

Keep only high-value automated checks such as:

- internal Markdown link check if it can be implemented cheaply;
- examples that are generated directly from one canonical config/template only when drift would be dangerous;
- CLI help smoke execution;
- `docker compose config` against the committed example/default config.

Do not rebuild V1's large workflow of grep-based stale-term lists, Make-target discovery, flag discovery and duplicated version-pin assertions. The application/config validator should own those contracts.

Exact prose is not a test target.

---

# 9. Documentation acceptance criteria for beta

A new administrator should be able to answer, from the five operator docs:

- Is my host supported?
- What Cloudflare/provider preparation is required?
- How do I install?
- Where is configuration stored?
- How do I change a secret safely?
- How do I check whether the system is healthy?
- How do I read logs?
- How do I back up?
- Where is the offline recovery material?
- How do I recover onto a new host?
- How do I update?
- Which scheduled jobs should be running?

If the answer requires `docs/SCRIPTS.md`, a generated command encyclopedia or knowledge of internal file synchronization, the V2 implementation has become too complicated.
