# AGENTS.md — VaultWarden-OCI repository map

## Start here

VaultWarden-OCI is a fresh-install Vaultwarden appliance for a small team of roughly 10 users, operated by a junior administrator on Ubuntu 24.04 LTS. `amd64` and `arm64` are supported/tested targets. The runtime is cloud-provider neutral, with Cloudflare as the supported public-edge model.

The product was developed greenfield using an earlier implementation only as a source of proven operator/security/recovery lessons. **The earlier UI/UX is a design reference; the earlier backend architecture is not a compatibility target.** Do not recreate Make-based orchestration, Postfix/queues, backup tiers, migration compatibility, broad helper libraries, or the old test architecture.

For each task, use this order of authority:

1. explicit human instructions for the current task;
2. `docs/PROJECT-BOUNDARY.md` and `docs/DECISIONS.md` as the durable product/implementation contract;
3. the administrator manuals (`README.md`, `docs/INSTALL.md`, `docs/OPERATIONS.md`, `docs/SECURITY.md`, `docs/RECOVERY.md`);
4. this file as the repository map;
5. historical material only as evidence/rationale unless the human explicitly promotes it for the task.

`reports/TEST-STRATEGY.md` is the current supporting validation policy. Obsolete workstream prompt archives are not product authorities and do not belong in the normal repository surface.

## Product invariants

- Ubuntu 24.04 LTS only; `amd64` and `arm64` supported/tested.
- Production persistent application state must live on a dedicated storage filesystem/volume. A root-only host is not a supported production install.
- The normal first-run human path is `setup.sh`: validate host/storage, install dependencies and the appliance, prepopulate config from operator inputs, assist secrets/recovery custody, then leave an explicit config/secrets -> start path.
- `setup.sh` supports interactive mode, `--auto`, and an independent explicit `--use-latest` override. Terminal-driven `--auto` may generate the separate offline Age identity only when no `--offline-recipient` was supplied, keep that private identity only in root-owned volatile storage, and require verified recovery-kit handoff before deleting it. Fully headless `--auto` requires an existing public `--offline-recipient`. An explicitly supplied recipient is authoritative and must never be silently replaced. Frontend custody decisions must use the same authoritative CLI grammar/parser as the installer rather than ad-hoc raw-token inspection.
- `--use-latest` resolves once to exact immutable values and must never leave floating `latest` state. The setup frontend must interpret `--use-latest` and `--auto` through the same CLI grammar used by the installer so supported value/long-option forms cannot bypass confirmation semantics.
- `dashboard.sh` is a supported day-2 human interface. `vwctl` remains the implementation/mutation authority. One implementation authority does not mean one user interface.
- Retain useful color-coded/AMTM-style interaction conventions from the earlier product as the visual/interaction reference.
- Python 3.12 standard-library-first owns structured config/state/validation/update/recovery logic. Bash remains thin bootstrap/UI/host glue where materially simpler.
- One operator-editable non-secret authority under `/etc/vaultwarden-oci`, one encrypted SOPS secret document, and one source-controlled exact version manifest.
- SOPS + Age remains the secret mechanism. The operational Age private key is root-only. The separate offline recovery private identity is never persistent server state; it normally stays off-host and may exist on the appliance only transiently in root-only volatile storage during the supported first-run recovery-kit handoff.
- A password-protected recovery-kit ZIP is a separate credential-handoff artifact from the normal encrypted `.vwrec` application recovery point.
- Caddy remains an exact-pinned xcaddy custom build with Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP support, combined Cloudflare IP ranges, and Caddy rate limiting.
- Caddy's Cloudflare trusted-proxy module owns real-client-IP trust. Do not also generate a static trusted-proxy CIDR block in Caddy.
- Host-level Cloudflare-only origin protection is separate: keep one small fail-closed Docker `DOCKER-USER` path allowing published HTTPS only from validated Cloudflare ranges.
- CrowdSec remediates proxied web-client decisions through Cloudflare; no CrowdSec host firewall bouncer is required.
- Preserve lightweight `/admin` defense in depth: Vaultwarden admin token, Caddy-side rate limiting, and one simple outer authentication gate.
- Vaultwarden application mail uses direct authenticated SMTP. Operational notification providers remain the closed source-controlled catalog.
- CyberPersons current catalog behavior is authoritative unless official provider documentation is deliberately re-verified for a focused change: `503` is status-only retry/fallback eligible; `429` account-wide quota/rate-limit and `500 send_failed` are not transient by status alone.
- One encrypted `.vwrec` application recovery format; no public db/full/emergency tier model and no compatibility reader for the earlier archive format.
- Restore retains explicit noninteractive CLI forms and also has a guided local/remote picker for humans.
- Recovery-kit ZIP: AES-256, passphrase entered/confirmed interactively, independent of stored credentials, never argv/env/file/email, fully verified before email is attempted.
- Application updates are operator-driven: discover a stable project release, stage/download/build before downtime, verify a pre-update recovery point, activate an immutable release, health-gate it, and roll back coherently when safe. Automatic checking/notification is supported; unattended apply is not the default.
- Direct source-layout update compatibility is guaranteed only from the explicitly tested supported predecessor release. The public updater does not offer arbitrary intermediate-release selection; do not promise undocumented incremental hops. Older unsupported development snapshots require a fresh supported install/recovery path unless a specific transition is deliberately implemented.
- Ubuntu package updates are separate from application updates. Application recovery does not claim to roll back apt/kernel changes. Never auto-reboot.
- Normal product surfaces are release-neutral. Do not introduce product-generation, branch-stage, preview, or implementation-stage names into runtime/docs/file names. Genuine technical schema/archive/release version values remain valid compatibility identifiers.

## Implementation ownership

Use Python 3.12 standard-library-first for structured logic: CLI parsing, TOML/config/version handling, validation, subprocess orchestration, locking, diagnostics, secrets orchestration, notification classification, recovery metadata, rclone orchestration, update transactions, and edge policy.

Use Bash only for the smallest bootstrap, interactive operator UI, host/container glue, or cases where shell is materially simpler. Do not let Bash become the owner of structured configuration, retry policy, state machines, complex locking, or recovery/update transactions.

`vwctl` is the mutation/implementation authority. `dashboard.sh` and `setup.sh` may orchestrate or present supported human workflows, but they must call into the same authoritative implementation rather than reimplementing state mutations. `vaultwarden_oci/setup_frontend.py` owns only the first-run human custody wrapper; the install parser and installation mutations remain in `setup.py` and existing owners.

The installed operator-editable non-secret config authority is `/etc/vaultwarden-oci/config.toml`; the source-controlled version authority is `versions.toml`. `email-providers.toml` is immutable release metadata, not a second operator-editable config authority.

## Design discipline

Prefer the smallest coherent owner and fewest clear files. Do not add speculative frameworks, dynamic plugin/provider registries, ORMs, daemons, databases, event buses, workflow engines, generic transaction frameworks, distributed locks, Kubernetes/Swarm/HA abstractions, storage abstractions, updater daemons, monitoring stacks, or generic cloud/notification/firewall frameworks without an explicit product decision.

Do not recreate earlier Make orchestration, Postfix/local MTA, backup tiers, broad repair commands, generic Docker cleanup, or migration compatibility. A useful earlier UI/security behavior may be copied conceptually; its implementation shape is not required.

## Testing and working rules

Use three permanent validation layers: focused unit tests, small integration tests, and disposable real-host Ubuntu 24.04 release acceptance. Test security, availability, recoverability, and operator truthfulness rather than private source structure.

Before editing, confirm the current branch/head and inspect the existing owner of the behavior. Keep changes bounded to the assigned task. Preserve secret redaction, fail-closed security boundaries, truthful success/failure reporting, and recoverability.

For setup/custody changes, test both terminal-driven and fully headless `--auto`, explicit-recipient preservation in supported CLI forms, failure before storage mutation when headless custody is missing, and transient-key cleanup only after successful handoff.

Run validation proportional to the change and report exactly what ran and what did not. Never claim host, architecture, provider, CI, destructive, or release validation that was not actually performed.
