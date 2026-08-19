# VaultWarden-OCI V2 Greenfield Audit

Date: 2026-08-18
Audit snapshot: `main` at `16dc4c82a57234f8de8b54aa709a8ef32831f4e6`
Revision: two additional repository rescans completed after the initial audit.

## Executive conclusion

The initial recommendation stands, but the rescans make it stronger: **V2 should be a greenfield reimplementation, not a V1 refactor.** V1 has strong security instincts and careful failure handling, but the project now spends too much engineering effort maintaining implementation machinery, tests that mirror that machinery, generated documentation, compatibility behavior, and installed-runtime synchronization.

V2 should preserve the security properties, not the mechanisms.

The highest-value changes are now:

1. make Python 3.12 the primary language for structured application logic;
2. keep Bash only for a very small bootstrap/host-glue surface where shell is clearer;
3. replace the broad Make/script/utility API with one `vwctl` operator CLI;
4. adopt one installed non-secret configuration authority and one encrypted secrets authority;
5. centralize version pins and `--use-latest` resolution;
6. remove V1 migration and format compatibility entirely;
7. reduce the test system to behavior that protects security, data, lifecycle, configuration and diagnostics;
8. remove implementation-text regression tests unless source structure itself is the security contract;
9. replace the current large host-acceptance controller with a small release-gate acceptance checklist/harness;
10. rewrite the repository agent instructions before Codex begins V2 implementation so the agent is not instructed to recreate V1.

## Fixed V2 product boundary

- Ubuntu 24.04 LTS Noble.
- Tested `amd64` and `arm64` support.
- Cloud-provider-neutral runtime; OCI A1 Flex is a reference deployment, not a dependency.
- Small team, roughly ten users, managed by a junior administrator.
- Cloudflare-first edge security and CrowdSec retained.
- Caddy retained as reverse proxy/TLS endpoint unless a later ADR deliberately changes ingress architecture.
- SOPS + Age retained for secret custody.
- `--use-latest` retained only for development/testing.
- Fresh-install V2 only. No V1 project-state, backup-format or migration compatibility requirement.
- No Kubernetes, HA, distributed state, plugin framework, generic cloud abstraction or enterprise monitoring stack.

---

# Rescan 1 — complexity and test-cost audit

## Test footprint

Using the tracked file sizes in the audited Git tree as a rough maintenance-footprint proxy:

- the `tests/` tree is approximately **1.18 MB across 30 tracked test files**, including 25 physical `case-*.bash` files exposed as 32 logical cases by the custom runner;
- the root/lib/utility shell implementation plus Makefile is approximately **1.94 MB**.

Source-byte counts are **not** engineering-effort or logical-line measurements. They are included only as a rough corroborating signal: the tracked test tree is about **61% of the byte size of that first-party shell/Make implementation set**. The effective validation footprint is larger because significant acceptance/validation code also lives outside `tests/`, including `utilities/noble-host-acceptance.sh`, `utilities/pre-production-drill.sh`, `utilities/smoke-test.sh`, and large workflow-side invariant checks.

The recent repository history also shows sustained test/CI iteration around host acceptance and exact structural validation. That is consistent with the reported experience that tests consume more than half of development effort.

## Finding V2-TEST-01 — tests duplicate implementation knowledge

Several large V1 tests do more than exercise behavior. They:

- `grep` for exact implementation strings;
- assert relative source-code ordering;
- extract production functions with `awk`/`sed` into synthetic harnesses;
- recreate fragments of production state machines;
- mock command behavior at a level nearly as complex as the production owner;
- validate documentation against implementation with additional textual policy logic.

These tests are understandable responses to complex Bash, but they make safe refactoring expensive. A semantically equivalent implementation change can require substantial test rewrites because the test is coupled to source shape rather than observable behavior.

### V2 decision

Do not port these tests. Rewrite only the tests needed by the V2 contract.

Use the separate `V2-TEST-STRATEGY.md` as the authoritative test policy.

## Finding V2-TEST-02 — the test runner has become a subsystem

The V1 runner owns logical IDs, physical cases, modes, per-case timeouts, GNU/BSD compatibility behavior, fixture remapping, inventory validation, compatibility wrappers and duration reporting.

That is too much permanent infrastructure for this product.

### V2 decision

Use ordinary Python tests for Python code. Prefer `pytest` as a development-only dependency with no plugins initially. Keep shell tests only for the few remaining shell entrypoints, using direct process invocation rather than a second test framework.

No custom logical test registry is required.

## Finding V2-TEST-03 — CI contains duplicated product policy

The current workflow independently encodes component pins, `--use-latest` locations, host assumptions, systemd hardening requirements, stale terms, CLI flags and generated command-reference rules.

This duplicates policy that also exists in scripts/configuration and creates more drift surfaces.

### V2 decision

CI should ask the application to validate its own declarative inputs where possible:

- `vwctl versions validate`
- `vwctl config validate --example`
- `docker compose config --quiet`
- `pytest`
- `ruff check`
- ShellCheck only for remaining shell

Do not reproduce the product schema in workflow Bash.

## Finding V2-TEST-04 — host acceptance should be a release gate, not everyday unit-test architecture

The current Noble acceptance controller is sophisticated enough to manage checkpoints, destructive reset survival, recovery material, rclone, DNS mutation, reboot and full DR. It is valuable evidence, but its own safety framework has become substantial code to maintain.

### V2 decision

V2 host acceptance should cover a small number of end-to-end golden flows on disposable Ubuntu 24.04 hosts and run manually/on release candidates rather than on every ordinary code change.

---

# Rescan 2 — architecture deletion and language-boundary audit

## Finding V2-AGENT-01 — current `AGENTS.md` will recreate V1

Current repository agent instructions intentionally tell an agent to preserve V1 architecture: Bash orientation, Postfix, three backup tiers, the operation-guard architecture, current test architecture, installed-runtime behavior and compatibility contracts.

That is correct for V1 maintenance but directly conflicts with greenfield V2.

### V2 decision

The **first V2 implementation PR must reset the agent contract** on a V2 development branch before writing runtime code. It must explicitly say:

- V1 is reference material, not an API compatibility target;
- do not port code unless the V2 design requires it;
- do not add compatibility adapters for V1;
- runtime Python standard library is preferred for structured logic;
- tests protect V2 behavior, not V1 source shape;
- every phase has explicit non-goals;
- do not implement later phases opportunistically.

## Finding V2-LANG-01 — Bash is doing application work

V1 Bash now implements configuration parsing, schema validation, secret workflows, version resolution, operation state, process/FD identity, backup manifests, archive selection, recovery transactions, diagnostic aggregation and terminal UI behavior.

This is the main cause of code/test multiplication.

### V2 decision — hybrid, explicitly bounded

**Python 3.12 standard library should own:**

- `vwctl` CLI and argument parsing;
- typed configuration loading/validation;
- versions manifest and latest-version resolution;
- architecture/platform mapping;
- subprocess execution/error normalization;
- operation locking and small runtime metadata;
- diagnostics/`doctor`;
- SOPS/Age orchestration and secret schema logic;
- backup metadata, retention, selection and restore preflight;
- Cloudflare CIDR parsing/validation;
- structured status/JSON output;
- file ownership/mode validation where practical.

**Bash should be limited to:**

- an initial bootstrap script if needed before the installed application exists;
- tiny system integration wrappers only when systemd/installer semantics are clearer in shell;
- Caddy/container entrypoint glue only where the upstream image requires it.

Do not add Go/Rust merely to produce a single binary. Python is already part of Ubuntu 24.04, is more readable for this team, and avoids another build/release toolchain.

Runtime Python should use the standard library unless a later requirement clearly justifies a dependency. Development may use `pytest` and `ruff`.

## Finding V2-LANG-02 — remove the YAML/yq/PyYAML triangle

V1 uses a YAML secret schema, `yq` readers and embedded Python/PyYAML semantic validation. That creates multiple parsers and version pins for one small schema.

### V2 decision

Prefer standard-library-readable formats:

- `config.toml` for non-secret configuration, read with `tomllib`;
- `versions.toml` for production pins;
- SOPS-encrypted JSON for secret values and simple JSON/schema metadata if a separate schema is still justified.

SOPS supports JSON input/output as well as YAML/dotenv/INI. This allows V2 to remove the runtime `yq`/PyYAML requirement entirely.

Reference: https://github.com/getsops/sops

## Finding V2-LANG-03 — Python materially simplifies locking

V1's operation guard contains extensive Bash machinery to keep lock descriptors out of descendants and prove process/FD identity.

Python can hold a single `fcntl.flock()` in the controlling process and launch children with descriptors closed. This removes the need for a separate Bash lock-holder process and much of the `/proc` bookkeeping.

### V2 decision

Start with **one global mutating lock**. Do not add operation-specific locks until a demonstrated need exists. Read-only `status`/`doctor` commands should not take it.

## Finding V2-UX-02 — defer the dashboard

The V1 dashboard is another large command-routing/UI surface tied to Compose, Make and numerous operational commands.

### V2 decision

Do not implement an interactive dashboard in V2 beta. Make `vwctl status` and `vwctl doctor` excellent first. A TUI can be reconsidered after real operator feedback.

## Finding V2-SCOPE-01 — delete migration, do not redesign it

`lib/migrate.sh` alone is a large stateful migration pipeline. V2 explicitly has no V1 data migration requirement.

### V2 decision

No migration framework, no old layout reader, no old backup reader, no compatibility aliases. V2 installation starts empty.

## Finding V2-MAIL-01 — direct SMTP should be the default

Vaultwarden supports authenticated SMTP with `SMTP_HOST`, security mode, credentials and standard submission ports. That makes a mandatory Postfix sidecar unnecessary for the normal small-team case.

Reference: https://github.com/dani-garcia/vaultwarden/blob/main/.env.template

### V2 decision

Use direct authenticated SMTP for Vaultwarden. Use Python `smtplib` for operational notifications through the same relay. Do not implement a local mail queue in V2 beta. If real deployments later prove a queue is required, Postfix can be evaluated as an optional profile with its own ADR.

## Finding V2-EDGE-03 — reduce custom CrowdSec provisioning

Current CrowdSec documentation recommends the self-hosted installer path for the Cloudflare Worker bouncer for most users.

Reference: https://docs.crowdsec.net/u/bouncers/cloudflare/

### V2 decision

Before porting V1's large CrowdSec setup script, evaluate the current supported upstream installer/configuration path. Project code should own only VaultWarden-specific configuration, credentials, validation and diagnostics.

## Finding V2-NET-04 — correct the firewall simplification boundary

Docker's documentation states that published container traffic can bypass ordinary UFW `INPUT`/`OUTPUT` filtering because Docker diverts traffic through its NAT/forwarding path.

Reference: https://docs.docker.com/engine/network/packet-filtering-firewalls/

### Revision to the initial proposal

V2 must **not** rely on UFW alone for a publicly published Caddy container.

For the initial V2 architecture, choose one explicit supported model:

- Docker bridge networking with the iptables backend;
- a very small project-owned ingress chain in the Docker packet path;
- Cloudflare CIDR restriction for published web ports;
- fail closed if that supported packet-path contract cannot be established.

Do not support both iptables and nftables backends in V2 beta. Do not build a generic firewall abstraction. A future ADR may choose Cloudflare Tunnel or host-level Caddy instead, but V2 should ship one ingress model, not several.

---

# Security properties to preserve

Keep these V1 properties even when their implementations change:

- fail closed before destructive storage/restore mutation;
- root-owned production mutation;
- encrypted persistent secrets and volatile decrypted secret files;
- offline recovery identity not persisted to the host;
- container capability minimization and read-only roots where supported;
- Cloudflare-restricted origin exposure;
- CrowdSec edge enforcement for proxied client decisions;
- verified database snapshot before backup publication;
- backup integrity verification before declaring success;
- restore preflight before service stop;
- explicit service-start policy after restore;
- exact non-zero failure when a required validation did not complete;
- pinned/checksummed production dependencies.

# Features that should not cross the V2 boundary by default

- V1 migration pipeline;
- V1 backup/archive compatibility;
- three public backup tiers;
- mandatory Postfix and queue administration;
- dashboard/TUI;
- generated 70+ KB command-reference document;
- Makefile as an operator API;
- repo `.env` as production authoring state;
- repo-to-`/opt` script synchronization/validation machinery;
- multi-mode custom Bash test runner;
- source-grep regression suites;
- multiple firewall backend support;
- macOS production/runtime compatibility;
- provider-specific cloud code.

# Priority

**P0 — before any V2 implementation:** product boundary, V2 `AGENTS.md`, language boundary, test budget, ingress model, Postfix decision, backup/recovery model.

**P1 — V2 foundation:** `vwctl`, config/versions, lock, diagnostics, installed release layout, minimal Compose.

**P2 — security/data:** SOPS/Age, Cloudflare/firewall, CrowdSec, backup/restore.

**P3 — operations/release:** systemd, notifications, updates, release acceptance, documentation.

The guiding rule remains:

> V2 should be easier to understand than V1. Any new abstraction must delete more operational complexity than it introduces.
