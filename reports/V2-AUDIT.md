# VaultWarden-OCI V2 Greenfield Audit

Date: 2026-08-18
Audit snapshot: `main` at `16dc4c82a57234f8de8b54aa709a8ef32831f4e6`
Revision: two additional repository rescans plus consolidation of later SOPS/Age, rclone, notification, and `v2` branch decisions.

> **Agent-execution precedence:** `reports/V2-CODEX-PROMPTS.md` is the authoritative V2 agent execution contract. This audit records findings/rationale. If it conflicts with the prompt contract, the prompt contract wins and this audit should be corrected.

## Executive conclusion

V1 contains substantial security and operational engineering, but it also accumulated a large amount of Bash application logic, compatibility behavior, state synchronization, public command surface, recovery variants, email-queue machinery, and tests coupled to internal implementation shape.

V2 should **not** be a mechanical refactor of V1. It should be a smaller greenfield implementation that preserves the strongest security/recoverability properties while removing historical compatibility and duplicated authorities.

The dedicated V2 development branch now exists as `v2`. PRs for V2 implementation should target that branch, with Phase 0 resetting the agent/product contract before runtime coding.

## Fixed V2 assumptions

- fresh install; no V1 data/state/archive migration requirement;
- Ubuntu 24.04 LTS Noble only;
- amd64 and arm64 tested targets;
- small team of roughly 10 users and junior-admin operation;
- runtime cloud-provider neutral;
- OCI A1 Flex reference deployment only;
- Cloudflare-first production ingress;
- CrowdSec retained;
- `--use-latest` retained only for development/testing resolution;
- security-first but intentionally lower complexity/maintenance cost.

## Repository complexity findings

The V1 codebase contains very large shell surfaces. Examples from the audited tree include roughly:

- `lib/secrets.sh` ~98 KB;
- `lib/migrate.sh` ~91 KB;
- `utilities/backup-run.sh` ~100 KB;
- `utilities/restore-run.sh` ~157 KB;
- `utilities/setup-secrets.sh` ~119 KB;
- `utilities/setup-crowdsec.sh` ~102 KB;
- `dashboard.sh` ~43 KB;
- `maintenance-health.sh` ~58 KB;
- a broad Makefile/operator command surface.

The problem is not that Bash is intrinsically insecure; it is that structured application behavior has expanded beyond a size where shell remains the clearest/cheapest owner.

V2 therefore uses Python 3.12 stdlib-first for structured application logic and keeps Bash only for minimal bootstrap/host/container glue.

## Agent-instruction finding

The V1 root `AGENTS.md` is appropriately detailed for preserving V1 behavior, but it actively conflicts with V2 greenfield goals by instructing agents to preserve Bash-first architecture, Postfix, existing backup tiers, existing operation/test architecture, and compatibility surfaces.

This is why Phase 0 must run before runtime coding.

The corrected V2 model is:

- root `AGENTS.md` becomes a concise map;
- it directs agents to `reports/V2-CODEX-PROMPTS.md`;
- the Codex prompt file is the authoritative agent execution contract;
- supporting ADRs/reports explain decisions but do not become competing instruction manuals;
- phase prompts are bounded and later phases must not be implemented opportunistically.

## Test/maintenance rescan

The tracked V1 `tests/` tree is approximately 1.18 MB across 30 files. Compared with the audited first-party root/lib/utilities shell + Make implementation set (~1.94 MB), the test tree is roughly 61% by byte size. Adding acceptance/validation scripts/workflows makes the validation footprint larger still.

This is only a source-size/maintenance-footprint signal, not an LOC or engineering-effort metric. However it matches the qualitative finding that test maintenance consumes substantial development attention.

The deeper issue is test coupling. Large V1 cases commonly:

- grep exact private source strings;
- assert source ordering;
- extract private functions via `awk`/`sed`;
- construct synthetic Bash harnesses;
- duplicate or mock internal state machines.

The canonical test runner itself maintains logical/physical inventories, modes, timeouts, compatibility handling, fixture rewrites, and registry validation. Host acceptance also grew into a large stateful controller.

V2 response:

- do not port the V1 test corpus;
- unit + small integration + disposable real-host release acceptance only;
- no custom runner/inventory;
- no coverage percentage gate;
- no source-string/private-helper tests;
- one behavior usually has one best permanent test layer;
- backup/restore gets disproportionate attention;
- test-size thresholds are review warnings, not targets/CI quotas.

## Configuration/state finding

V1 has multiple runtime authorities and substantial code devoted to safely parsing/synchronizing environment/config/install state.

V2 should have:

- one installed non-secret config: `/etc/vaultwarden-oci/config.toml`;
- one source-controlled versions manifest: `versions.toml`;
- one structured SOPS-encrypted secrets document;
- one root-only operational Age identity;
- volatile decrypted runtime secret files only;
- immutable application releases under `/opt/vaultwarden-oci/releases/<release>` with a `current` symlink.

Avoid repository `.env` -> installed env -> generated env synchronization chains and multiple operator-editable sources of truth.

## SOPS + Age decision

SOPS + Age remains a good fit for V2 and should be retained.

The improvement is simplification:

- SOPS/Age are external trusted tools;
- project code owns only validation/orchestration;
- one encrypted structured secret document;
- one operational host identity;
- separate offline recovery material/recipient;
- no cloud-KMS/provider abstraction;
- no custom cryptography;
- plaintext exists only in root-owned volatile runtime paths when needed.

This preserves cloud neutrality and avoids the operational burden of running a separate secrets service for a ~10-user appliance.

## Email/notification finding and final decision

V1's Postfix sidecar, mutable queue state, queue commands, health logic, tests, capabilities, and documentation create a meaningful maintenance surface.

V2 beta should remove the mandatory Postfix/local queue architecture.

Split the two mail use cases:

### Vaultwarden application email

Vaultwarden uses direct authenticated SMTP through its supported configuration.

### Project operational notifications

Use:

`one concrete HTTPS email API -> small bounded retry -> authenticated SMTP transient fallback`

The concrete HTTPS API provider must be selected by ADR before Phase 6. Do not hide an undecided provider behind a generic plugin/provider framework.

Fallback is for clearly transient delivery-path failures such as network/DNS timeouts, `429` after bounded retry, and service-side `5xx`. Representative `400`/`401`/`403`, invalid configuration/permanent rejection, and TLS certificate/hostname validation failures should remain visible rather than being silently masked by SMTP success.

SMTP must use normal certificate/hostname validation, implicit TLS or required STARTTLS + authentication, bounded timeouts, and secrets from the V2 secret mechanism.

If both transports fail, save a small secret-free diagnostic result surfaced by `vwctl status`/`doctor`.

Do **not** build a spool, durable retry queue, dead-letter system, MTA, or provider registry. If durable local queuing later proves necessary in production, make that a new architecture decision; reconsidering a mature MTA would be preferable to recreating one in Python.

## rclone finding and final decision

rclone should remain first-class. It is not part of the V1 overengineering problem; it lets the project stay cloud-neutral without implementing storage-provider APIs.

Keep a small wrapper for:

- diagnostics/connectivity;
- upload/publication;
- remote listing/verification;
- download/staging;
- explicit retention/pruning;
- status/doctor visibility.

Normal publication should be:

`create -> verify local -> rclone copy/copyto -> verify remote -> success`

Deletion is separate. Do not use destructive `sync` semantics as the normal publication mechanism where missing local files could cause remote recovery deletion.

Do not wrap rclone in a generic storage-provider framework.

## Backup/recovery finding

V1's multiple backup/recovery tiers and compatibility/migration behaviors create a large code/test/documentation footprint.

Because V2 is greenfield, remove:

- V1 archive readers;
- V1 migration pipeline (including the ~91 KB migration library);
- public db/full/emergency tier model;
- compatibility adapters.

V2 exposes one encrypted recovery point format plus separate offline recovery material. Restore validates/decrypts/checks/stages before live mutation and health-gates any restart.

## Operation-lock finding

V1 contains complex process/lock-holder identity and operation-specific concurrency machinery.

V2 should begin with one global mutating lock using Python `fcntl.flock()`. Read-only commands do not take it. Do not add per-operation/distributed lock architecture without demonstrated concurrency requirements.

## Dashboard/health finding

The V1 dashboard and health subsystem add another large public/UI/dependency surface.

V2 beta should have no dashboard/TUI. Invest in:

- `vwctl status` for concise current state;
- `vwctl doctor [--json]` for read-only stable-ID diagnostics;
- systemd/journal/container logs for deeper investigation.

Do not combine doctor with a broad automatic repair framework.

## Cloudflare/Docker firewall finding

Docker-published ports are not governed like ordinary UFW INPUT traffic. V2 must not claim UFW alone protects a published Caddy port.

Beta supports one precise path:

- Cloudflare-proxied HTTPS;
- Docker bridge networking;
- Docker iptables packet-filter backend;
- one small project-owned ingress chain/allowlist;
- validated Cloudflare IPv4/IPv6 ranges;
- last-known-good cache with bounded staleness;
- fail closed when no safe policy can be established.

Do not implement simultaneous iptables/nftables/generic firewall backends in beta. Direct/non-Cloudflare ingress is a future explicit architecture decision.

## CrowdSec finding

CrowdSec remains valuable, but V2 should prefer current upstream installation/integration and own only project-specific acquisition/configuration, credentials, selected bouncer integration, and diagnostics.

Do not port the large V1 CrowdSec installer wholesale.

## Version/update finding

Centralize all owned component pins in one `versions.toml`.

Normal production paths use exact pins. `--use-latest` is explicitly for development/testing: resolve once, freeze exact results for the run, record them, then use those values. Do not spread live-latest conditionals across setup scripts/templates.

No unattended update daemon is required.

## Documentation finding

V2 should shrink documentation by shrinking supported behavior.

Target:

- `README.md`
- `docs/INSTALL.md`
- `docs/OPERATIONS.md`
- `docs/SECURITY.md`
- `docs/RECOVERY.md`
- `docs/DEVELOPMENT.md`

Use `vwctl --help` as executable command reference and stable doctor JSON/check IDs for machine-readable diagnostics. Do not preserve removed V1 surfaces in documentation.

## Recommended phase order

The detailed authoritative prompts live in `V2-CODEX-PROMPTS.md`:

0. reset agent/product contract and ADRs;
1. minimal Python foundation;
2. bootstrap/immutable installed layout;
3. Vaultwarden+Caddy core, SOPS/Age, Vaultwarden direct SMTP;
4. Cloudflare ingress + CrowdSec;
5. one recovery format + first-class rclone;
6. systemd + concrete HTTPS notification API + SMTP transient fallback;
7. pinned versions/update + dev/test `--use-latest`;
8. consolidated docs, real-host acceptance, V2 cleanup.

## Highest-risk ways to fail V2

1. letting agents treat V1 implementation shape as compatibility requirements;
2. recreating frameworks/providers/queues for hypothetical future flexibility;
3. allowing tests to couple to private source structure again;
4. multiplying config/state authorities;
5. using destructive remote synchronization as ordinary backup publication;
6. hiding notification authentication/security/config failures behind unconditional SMTP fallback;
7. supporting multiple firewall/network modes before the golden path is stable;
8. keeping V1 migration/backup compatibility despite the greenfield decision.

## Final recommendation

Merge the audit/design contract into `v2`, then run **Prompt 0 only**. Review the resulting `AGENTS.md`, product boundary, and ADRs—including the concrete HTTPS notification API provider decision—before allowing Phase 1 runtime code.

That sequence gives future agents a narrow, explicit source of truth and is the strongest control against recreating V1 complexity under a new language.