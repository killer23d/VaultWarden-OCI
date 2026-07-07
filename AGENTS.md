# AGENTS.md — VaultWarden-OCI Repository Instructions

## Purpose

This file contains durable repository-level instructions for agents working on VaultWarden-OCI.

It is not tied to a specific pull request, audit, finding list, or historical remediation effort.

Task-specific prompts may narrow the work further, but they must preserve the project architecture, supported production matrix, security model, and scope constraints documented here.

The current repository is always the implementation source of truth.

Previous reports, pull-request descriptions, comments, tests, and documentation are evidence and historical context. They are not substitutes for inspecting current executable behavior.

---

# Project context

VaultWarden-OCI is an opinionated, security-first, self-running Vaultwarden appliance for a small production deployment.

Expected production scale:

* approximately 10 users;
* one primary operator;
* the primary operator may be a junior Linux or Docker administrator;
* the stack is intended to be mostly "set and forget";
* close operator attention is expected mainly during incidents, failed health checks, backup failures, restore, disaster recovery, storage migration, key operations, maintenance, and updates;
* a few hours of downtime may be acceptable;
* avoidable full-working-day outages are not desirable.

This is not an enterprise platform or a generic Vaultwarden deployment framework.

Project priorities, in order:

1. Security.
2. Reliable backup, restore, and disaster recovery.
3. Truthful operator state and failure reporting.
4. Safe interruption and concurrency behavior.
5. Simple junior-operator workflows.
6. Useful failure notification.
7. Minimal moving parts.
8. Portability across the explicitly supported host matrix.
9. Avoid enterprise-style complexity unless a demonstrated production defect requires it.

---

# Supported production host matrix

The intended normal production host matrix is:

| Dimension            | Supported normal production path                                         |
| -------------------- | ------------------------------------------------------------------------ |
| Operating system     | Ubuntu 24.04 LTS Noble                                                   |
| CPU architecture     | amd64 or arm64                                                           |
| Host type            | Cloud VM, virtual machine, or physical host                              |
| Cloud provider       | Provider-neutral                                                         |
| Init/service manager | systemd                                                                  |
| Container runtime    | Docker Engine with Docker Compose plugin                                 |
| Edge provider        | Cloudflare                                                               |
| Storage              | Boot-volume state or an explicitly configured attached block/data volume |

The project must be designed and reviewed against both supported OS/CPU combinations:

```text
Ubuntu 24.04 Noble amd64
Ubuntu 24.04 Noble arm64
```

Do not describe the project as fully "CPU agnostic".

The supported CPU portability contract is:

```text
amd64 and arm64
```

Architectures such as:

* armhf;
* i386;
* ppc64el;
* s390x;
* riscv64;

are outside the normal supported production matrix unless the repository explicitly expands support and validates the complete stack on those architectures.

A dependency or helper supporting an additional architecture does not automatically make the complete VaultWarden-OCI stack supported on that architecture.

The full-stack support boundary is determined by the narrowest required production component.

---

# Ubuntu version portability contract

The normal production path must work on:

```text
Ubuntu 24.04 LTS Noble
```

Host setup code must not silently assume support for any other Ubuntu release.

Where Ubuntu release information is required:

1. read `/etc/os-release`;
2. require `ID=ubuntu`;
3. derive the actual version/codename from the host;
4. require `VERSION_ID=24.04`;
5. require codename `noble` from `VERSION_CODENAME` and/or `UBUNTU_CODENAME`;
6. fail if the version and codename are missing, unresolved, or inconsistent;
7. fail clearly on an unsupported or unresolved release.

Do not silently default to:

```text
noble
```

when host release detection fails.

A fallback that configures repositories for the wrong Ubuntu release is not acceptable.

Repository, package, and dependency installation paths must be checked against the Noble-only production contract.

Pay particular attention to:

* Ubuntu archive layout;
* `universe`;
* deb822 `.sources` versus traditional `.list` files;
* Docker apt repository setup;
* package names;
* package availability on Ubuntu 24.04 Noble;
* package implementation differences;
* systemd semantics;
* iptables versus nftables backend behavior;
* GNU utility behavior;
* Python packages/modules;
* `yq`;
* SOPS;
* Age;
* CrowdSec packages and repositories;
* firewall bouncer packages.

Do not infer compatibility merely because the same package name exists in another Ubuntu release or distribution.

If the project requires a specific command implementation or major version, validate that implementation explicitly.

For example, a command named `yq` is not sufficient proof if project syntax depends on a specific `yq` implementation or major version.

---

# CPU architecture portability contract

The supported normal production architectures are:

```text
amd64
arm64
```

Architecture detection should use stable host/package architecture information such as:

```bash
dpkg --print-architecture
```

where appropriate on Ubuntu.

Recognize equivalent kernel architecture names only at explicit boundaries where needed:

```text
amd64  <-> x86_64
arm64  <-> aarch64
```

Do not silently treat an unknown architecture as amd64.

Do not download amd64 artifacts on an unknown architecture.

Architecture-specific external artifacts must be mapped explicitly and fail closed when unsupported.

For every required architecture-sensitive component, verify the amd64 and arm64 path.

Important boundaries include:

* Docker Engine packages;
* SOPS installation artifacts;
* CrowdSec installation;
* CrowdSec firewall bouncer;
* Cloudflare Workers bouncer;
* Vaultwarden container image;
* BusyBox container image;
* Postfix container image;
* Caddy builder image;
* Caddy runtime image;
* Caddy plugin build chain;
* any directly downloaded release binary.

Docker Compose must not add:

```yaml
platform: linux/amd64
```

to the supported normal path unless a demonstrated upstream limitation intentionally makes a component amd64-only.

Pinned container images must be checked for both supported architectures.

A container image being generally "multi-arch" is not enough. The actual pinned tag used by the repository must resolve for both amd64 and arm64.

Where safe tooling is available, inspect manifests using commands such as:

```bash
docker buildx imagetools inspect IMAGE:TAG
```

or:

```bash
docker manifest inspect IMAGE:TAG
```

Do not pull or execute production state merely to inspect an image manifest.

Custom Caddy builds must be assessed on both amd64 and arm64.

The fact that the Caddy base image supports an architecture does not by itself prove every pinned xcaddy plugin builds successfully on that architecture.

---

# Cloud-provider portability contract

VaultWarden-OCI is intended to be cloud-provider neutral at runtime.

The project name is historical branding and does not make Oracle Cloud Infrastructure a runtime dependency.

The supported host may be:

* Oracle Cloud Infrastructure;
* AWS;
* Azure;
* Google Cloud;
* another VM provider;
* a private virtualization platform;
* a physical Ubuntu host;

provided the host satisfies the supported OS, CPU, systemd, Docker, networking, storage, and Cloudflare prerequisites.

The production scripts must not require:

* OCI CLI;
* Oracle Cloud APIs;
* OCI instance principals;
* OCI metadata endpoints;
* OCI-specific device names;
* OCI-specific VNIC discovery;
* OCI-specific security-list APIs;
* AWS metadata;
* AWS CLI;
* Azure instance metadata;
* Azure CLI;
* Google Cloud metadata;
* `gcloud`;
* provider-specific IAM credentials.

Provider-specific examples are allowed in documentation.

They must be clearly identified as examples or notes rather than universal requirements.

Do not hard-code the login user:

```text
ubuntu
opc
ec2-user
azureuser
```

Use the repository's established real-user/root-operation helpers.

External provider firewall configuration is an operator prerequisite.

The scripts may configure the supported Ubuntu host firewall, but they must not assume they can automatically configure the cloud provider's upstream firewall or security group.

Documentation should use generic wording such as:

```text
provider firewall / security group / network firewall
```

Provider-specific notes may then explain OCI, AWS, Azure, or another platform.

---

# Cloudflare boundary

Cloud-provider neutral does not mean edge-provider neutral.

Cloudflare is part of the supported normal production architecture.

The golden path requires Cloudflare for the project's chosen:

* DNS model;
* proxy;
* WAF;
* client IP handling;
* Caddy Cloudflare DNS-01 path;
* CrowdSec edge-enforcement integration.

Do not redesign the project into a generic edge-provider framework.

Do not create:

* a DNS provider registry;
* a WAF provider abstraction;
* a generic edge plugin system;
* a YAML provider registry.

Alternate TLS behavior that already exists may remain an advanced path.

It must not weaken or complicate the Cloudflare-first normal production path.

---

# Core architecture decisions

Preserve the current architecture unless a confirmed production defect requires a bounded change.

The normal stack includes:

* Vaultwarden;
* Caddy;
* Cloudflare;
* CrowdSec;
* Postfix sidecar where used by the current mail design;
* SOPS;
* Age;
* rclone offsite backup support;
* systemd services and timers;
* Docker Compose.

The current container count is intentionally lean.

Do not add a container merely to move shell logic into another process.

---

# Root-operated production model

The project uses a root-operated lifecycle and privileged maintenance model.

Production lifecycle and privileged operations intentionally use root where required.

Examples include supported forms such as:

```bash
sudo make up
sudo make restart
sudo make health
sudo make backup
sudo make restore
```

The established root-operated ownership and permissions contract must remain internally consistent.

Do not redesign the project around an unprivileged production operator merely because that model is possible.

Metadata and help paths should remain root-free where the executable contract intentionally supports root-free discovery.

Real privileged operations must enforce root before mutation.

A root check must not occur after meaningful host or production mutation.

---

# Secrets and key-custody model

The project uses SOPS + Age.

The operational Age private key is part of the established root-operated server configuration.

The optional offline recovery Age private key is stored offline and must not be persisted to the server.

An offline Age public recipient may be stored as configuration where required for SOPS recipient policy.

Do not confuse:

* Age public recipient;
* Age private identity;
* operational Age key;
* offline recovery Age key;
* emergency backup passphrase;
* backup encryption recipient.

The repository must not:

* print production secret values into ordinary logs;
* put secrets in process command arguments where avoidable;
* commit plaintext secrets;
* persist the offline recovery private key;
* weaken root-owned key permissions;
* present a key-preservation failure as successful recovery.

Temporary secret or private-key material must use restrictive permissions and reliable cleanup.

---

# Backup model

The project has three intentional backup tiers:

```text
db
full
emergency
```

Do not collapse the three tiers into one generic backup type.

The intended distinction is operational and security-relevant.

`db` is the fast database rollback path.

`full` is the normal disaster-recovery archive.

`emergency` is a clone-grade secrets-bearing capsule with independent protection according to the current implementation.

All success messages must reflect actual verification state.

Required backup verification failure must not be presented as full success.

Offsite protection not requested must be distinguished from offsite protection requested but skipped or failed.

Do not introduce a backup database or backup catalog service.

---

# Restore and disaster recovery

Restore and recovery are high-risk workflows.

Audit and change them using observable production contracts, not cosmetic source structure.

Important boundaries include:

* preflight;
* archive selection;
* decryption-key selection;
* emergency passphrase handling;
* pre-restore snapshot;
* service stop;
* SQLite/WAL handling;
* extraction/staging;
* permission repair;
* secrets/key handling;
* promotion;
* rollback;
* commit boundary;
* start policy;
* service startup;
* `/alive` health verification;
* final operator guidance.

An incomplete restore must not be presented as successful.

A recovery transaction must distinguish pre-commit failure from post-commit service/health failure.

Do not add a generic transaction framework, workflow engine, recovery database, or recovery state machine.

Prefer a local transaction boundary in the owning workflow.

---

# Storage portability

The repository supports:

* boot-volume state; and
* an explicitly configured attached block/data volume.

Storage logic must remain provider neutral.

Do not require an OCI-specific block-device path.

Use operator-supplied or host-stable device paths.

Where documentation gives a device example, prefer generic forms such as:

```text
/dev/disk/by-id/...
```

Do not assume:

```text
/dev/sdb
/dev/vdb
/dev/oracleoci/...
```

is universal.

The `.vw-data-volume` sentinel is a project ownership/safety contract.

Mounted-volume ownership ambiguity must fail closed before destructive fstab, mount, format, or cleanup operations.

Do not build a generic storage orchestration framework.

---

# Shared operation guard

Conflicting mutating workflows use the repository's shared `flock` operation-guard architecture.

The canonical implementation is in:

```text
lib/operations.sh
```

Kernel lock state is authoritative.

Operation metadata is descriptive and operator-facing.

Do not treat lock-file existence as evidence that an operation is active.

Preserve:

* global operation serialization where required;
* operation-specific locks where justified;
* inherited foreground lock support;
* verified owner PID/start identity;
* conservative stale metadata handling;
* controlled TERM-before-KILL behavior;
* refusal to automatically terminate package-manager work;
* exit `75` for expected non-interactive contention where the owning script/systemd contract uses it.

`--force` may bypass an explicit confirmation where documented.

It must not silently bypass the shared operation guard.

Read-only paths should not acquire the global mutating lock unless there is a demonstrated resource conflict.

Do not replace `flock` with a database, daemon, Redis, or distributed lock service.

---

# systemd model

Managed automation uses systemd.

Repository templates and installed runtime artifacts must remain consistent.

Inspect both:

```text
systemd/
```

and:

```text
utilities/setup-systemd.sh
```

when changing script paths, command grammar, environment paths, lock/runtime directories, or exit behavior.

Expected operation contention must not trigger false failure incidents.

Real failures must not be converted into clean contention success.

Installed-runtime validation should detect stale managed artifacts where the current production contract requires exact or rendered consistency.

Do not add a second scheduler.

---

# Operator CLI contract

The public shell-script interface is an operator API.

For supported public commands:

* help text must match executable grammar;
* canonical syntax must be clear;
* compatibility aliases must remain intentionally bounded;
* unknown arguments should fail clearly;
* required option values must be validated before shifting;
* options must apply only to subcommands that use them;
* metadata paths should not require production state unless intentionally necessary;
* real operations must retain root, environment, TTY, and safety requirements.

When changing a parser or canonical grammar, search every caller.

At minimum inspect:

* Makefile;
* dashboard;
* systemd units;
* top-level dispatchers;
* nested shell calls;
* tests;
* generated command reference;
* hand-maintained documentation.

A parser fix is incomplete if a legitimate internal caller still uses grammar the new parser rejects.

Do not introduce a generic CLI parser framework.

Use small local parser improvements consistent with neighboring scripts.

---

# Makefile and dashboard

The Makefile is primarily an operator/day-2 command surface.

It is not the canonical permanent test inventory.

`tests/run-tests.sh all` owns the permanent Bash test-suite inventory.

Every advertised operator Make target must have an obvious working privilege form.

Avoid contracts where:

```text
make TARGET
```

fails because the leaf requires root while:

```text
sudo make TARGET
```

is rejected by the Make root policy.

The dashboard is a junior-operator interface.

A status not checked is not healthy.

Use truthful states such as:

```text
Ready
Not ready
Configured
Not configured
Unknown
Skipped
Failed
```

Do not derive green health from a failed or unavailable probe.

Prefer deleting a weak status line over building a parser, cache, or status database to make it appear authoritative.

---

# Tests and CI

The canonical permanent Bash test entry point is:

```bash
./tests/run-tests.sh all
```

The permanent suite is organized by production domain.

Do not create one test file per issue, PR, or finding.

Do not restore historical single-purpose test sprawl merely for assertion-count parity.

When consolidating or changing tests, preserve meaningful production behavior coverage.

Distinguish:

* real behavioral execution tests;
* mocked behavioral tests;
* structural/static assertions;
* string/grep assertions.

A static assertion is acceptable when source structure is the contract.

For high-risk runtime control flow, prefer behavioral or focused mocked-behavior coverage where practical.

Important regression domains include:

* architecture and host portability;
* privilege/security;
* permissions;
* configuration/environment;
* secrets;
* operation guards;
* lifecycle;
* systemd;
* email;
* storage/migration;
* backup;
* restore/recovery;
* operator UI;
* CrowdSec;
* uninstall/test reset.

CI and local developer wrappers must not maintain separate permanent test inventories.

---

# Portability regression expectations

Repository changes affecting host installation, dependencies, images, storage, networking, or systemd must be reviewed against the supported matrix:

```text
Ubuntu 24.04 Noble amd64
Ubuntu 24.04 Noble arm64
```

This does not require destructive CI on two real production hosts for every change.

Use the lowest-cost useful validation layer.

Examples:

* static architecture mapping tests;
* `/etc/os-release` fixture tests;
* package/repository rendering tests;
* container manifest inspection;
* Compose validation;
* mocked host-command behavior;
* GitHub Actions matrix testing where practical;
* dedicated production-host acceptance testing for destructive or systemd/storage behavior.

Do not claim a matrix combination is proven when the available test only exercises another OS or CPU.

A macOS test result is useful for shell/parser behavior.

It is not proof of:

* Linux `/proc`;
* util-linux `flock`;
* systemd;
* apt/dpkg;
* Ubuntu package behavior;
* iptables/nftables;
* block-device handling.

Record the validation limit honestly.

---

# External dependency validation

Do not assume a dependency is compatible merely because installation succeeds.

For required commands, validate the interface the repository actually needs.

Important examples include:

* Bash major version;
* Docker Engine;
* Docker Compose plugin;
* SOPS;
* Age;
* `yq`;
* `jq`;
* SQLite;
* rclone;
* rsync;
* GNU coreutils;
* CrowdSec;
* firewall tooling.

If repository code relies on implementation-specific syntax, test that syntax or validate the required implementation/version.

Prefer a clear early dependency failure over a later secrets, restore, or migration failure.

Do not add a general dependency framework solely for abstraction.

---

# Security and failure-reporting rules

The following are not acceptable:

* silent data loss;
* production secret/private-key exposure;
* incomplete restore presented as successful;
* incomplete recovery presented as successful;
* required backup verification failure presented as complete protection;
* concurrent conflicting mutation caused by a guard gap;
* unsafe termination of apt/dpkg/package repository work;
* lock bypass hidden behind `--force`;
* stale operation metadata causing unsafe operator action;
* systemd hiding a real operation failure as expected contention;
* expected timer contention generating a false incident;
* an SSH disconnect leaving unsafe key or startup guidance;
* direct supported script invocation silently having weaker safety than the Make path;
* a skipped or unavailable required readiness check presented as healthy;
* unsupported Ubuntu release fallback silently using Noble repositories;
* unsupported CPU architecture silently receiving another architecture's binary;
* a cloud-provider-specific assumption hidden in the normal provider-neutral path.

---

# Scope control and rejected overengineering

Before proposing a broad design, ask:

> Can this defect be fixed by correcting one caller, reusing an existing canonical helper, deleting misleading behavior, tightening a local transaction, adding one explicit architecture/release mapping, or adding a focused regression?

Prefer the smallest coherent fix.

Do not introduce without a demonstrated production requirement:

* Kubernetes;
* Docker Swarm orchestration;
* multi-node HA;
* distributed locks;
* Redis;
* an external workflow engine;
* an operation database;
* an audit event database;
* a generic transaction library;
* a recovery state database;
* a generic parser framework;
* a command registry;
* a plugin registry;
* a YAML provider registry;
* a generic cloud-provider abstraction;
* a generic CPU architecture abstraction;
* a policy engine;
* a new daemon;
* a new monitoring stack;
* a service mesh;
* a new secrets manager;
* a generic readiness framework;
* a generic install framework;
* broad refactors for line count;
* broad rewrites for stylistic uniformity.

This project values clear Bash, Make, systemd, Compose, SOPS/Age, and focused tests.

Keep that architecture unless current production evidence requires otherwise.

---

# Evidence discipline for audits and reviews

When auditing the repository:

1. Record the exact branch and commit SHA.
2. Inspect current executable code first.
3. Derive the actual current contract.
4. Inventory supported entry points and automation callers.
5. Trace realistic end-to-end execution paths.
6. Compare callers, callees, tests, systemd, Make, and documentation.
7. Use previous reports to understand history and accepted decisions.
8. Do not reuse old findings without verifying the current code.
9. Do not assume a closed finding cannot regress.
10. Report only confirmed or strongly traceable defects.

The required mindset is:

```text
current repository
    ->
derive actual architecture and supported matrix
    ->
inventory supported entry points
    ->
trace production workflows
    ->
challenge cross-component contracts
    ->
validate against tests and automation
    ->
report evidence
```

Not:

```text
old report
    ->
check boxes
    ->
run tests
    ->
declare complete
```

A clean review is an acceptable result.

Do not invent findings to justify an audit.

Distinguish:

```text
confirmed code defect
```

from:

```text
missing automated coverage
```

from:

```text
production-host validation requirement
```

These are not interchangeable.

---

# Documentation rules

Documentation must reflect the supported normal production matrix:

```text
Ubuntu 24.04 LTS Noble
amd64 or arm64
provider-neutral host
Cloudflare-first edge
```

Provider-specific deployment notes are acceptable.

They must not make the provider appear mandatory unless the executable code actually requires it.

Do not rewrite all documentation for small wording differences.

Update only materially incorrect:

* commands;
* paths;
* support claims;
* safety procedures;
* recovery steps;
* key-custody instructions;
* backup semantics;
* storage behavior;
* privilege requirements;
* supported OS/CPU/provider statements.

Generated documentation must be regenerated through the established repository generator.

Do not hand-edit generated output when the source/generator owns the content.

---

# Change discipline

Before editing:

* inspect the current branch;
* inspect nearby code;
* identify callers;
* identify existing tests;
* understand the current production contract.

During editing:

* keep the change bounded;
* preserve established architecture;
* add focused regression coverage for corrected production behavior;
* avoid unrelated cleanup.

After editing, run the strongest safe applicable validation.

Common validation includes:

```bash
git diff --check

find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 -n 1 bash -n

find . \
  -path './.git' -prune -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 shellcheck -x --severity=warning

bash tests/run-tests.sh all

docker compose \
  --env-file .env.example \
  -f docker-compose.yml.example \
  config --quiet
```

Run focused domain tests in addition to the full runner when the affected behavior is high risk.

Do not claim a command passed when it was not run.

Document skips and environment limitations.

At completion, inspect:

```bash
git status --short
git diff --check
git diff --stat
git diff
```

The final change set must contain only intentional work.
