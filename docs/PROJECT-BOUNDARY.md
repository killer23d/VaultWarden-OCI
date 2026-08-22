# VaultWarden-OCI product boundary

VaultWarden-OCI is a fresh-install Vaultwarden appliance for a small team of roughly 10 users and a junior administrator. The earlier product remains a useful UI/UX, security, and behavioral reference; its backend architecture is not a compatibility target.

## Supported production path

- Ubuntu 24.04 LTS only.
- `amd64` and `arm64` are supported/tested architectures.
- Runtime behavior is cloud-provider neutral.
- Production persistent application state must live on a separate storage filesystem/volume. A host whose production state resides only on the boot/root filesystem is unsupported.
- Cloudflare-proxied production ingress with Caddy.
- Docker bridge networking with one small project-owned `DOCKER-USER` origin-filter path that permits published HTTPS only from validated Cloudflare source ranges, uses bounded last-known-good state, and fails closed when no safe policy is available.
- CrowdSec remediates proxied web-client decisions through Cloudflare. A CrowdSec host firewall bouncer is not required.
- Python 3.12 standard-library-first owns structured logic; Bash is limited to bootstrap, supported interactive UI, and host/container glue where materially simpler.
- `vwctl` is the implementation and mutation authority.
- `dashboard.sh` is a supported day-2 human interface. One mutation authority does not mean one user interface.
- The normal first-run human path is `setup.sh`: validate host/storage, install dependencies and appliance content, prepopulate config from operator inputs, assist secrets/recovery custody, then leave an explicit config/secrets -> start path.
- `setup.sh` supports interactive operation, `--auto`, and an independent explicit `--use-latest` override. `--use-latest` resolves remote versions once to exact immutable values; no floating `latest` state may remain after resolution.
- One installed operator-editable non-secret config authority under `/etc/vaultwarden-oci` (currently `config.toml`).
- One source-controlled exact version authority: `versions.toml`.
- One structured encrypted SOPS secret document.
- SOPS + Age uses one root-only operational Age private identity and a separate offline recovery identity whose private key is not persistently stored on the server.
- Vaultwarden application mail uses direct authenticated SMTP.
- Operational notifications use the existing closed source-controlled provider catalog. Operator config may select supported providers/options but may not define arbitrary endpoints, authentication modes, request templates, success rules, or retry rules.
- CyberPersons current verified behavior is preserved unless official provider documentation is deliberately re-verified for a focused change: `503 service_unavailable` is status-only transient/retry/fallback eligible; `429 rate_limit_exceeded` and `500 send_failed` are not transient by status alone.
- rclone is first-class for offsite recovery publication and retrieval.
- One encrypted `.vwrec` application recovery format plus separate offline recovery material. No public `db`/`full`/`emergency` tier model and no compatibility reader for the earlier archive format.
- A password-protected recovery-kit ZIP is a separate credential-handoff artifact from `.vwrec` application recovery points.
- systemd is the lifecycle/scheduling authority.
- Production versions are exact pins.

## Caddy and edge security

Caddy remains an xcaddy custom build with all required modules exact-pinned:

- Cloudflare DNS;
- Cloudflare trusted-proxy/real-client-IP support;
- combined Cloudflare IP ranges;
- Caddy rate limiting.

Caddy's Cloudflare trusted-proxy module owns real-client-IP trust. Do not generate a second static Cloudflare trusted-proxy CIDR block in Caddy.

That is distinct from origin protection. The host-level `DOCKER-USER` path still validates Cloudflare IPv4/IPv6 ranges and permits published HTTPS only from those source ranges. The trusted-proxy module does not replace this fail-closed origin firewall.

Preserve lightweight `/admin` defense in depth: Vaultwarden's admin token plus Caddy-side rate limiting and one simple outer authentication gate. Do not add an enterprise identity stack or redundant authentication layers.

## Recovery and credential handoff

Normal application recovery is one encrypted `.vwrec` format. Restore must validate/decrypt/check/stage before live mutation and retain explicit noninteractive CLI forms for automation. The human restore experience also provides a guided local/remote picker in the useful style of the earlier product.

The recovery-kit ZIP is not an application recovery point. It is a separate credential-handoff artifact using AES-256 ZIP encryption. Its passphrase is entered and confirmed interactively, independent of stored credentials, never supplied through argv/environment/files/email, and the encrypted ZIP must be fully verified before any email attempt.

Normal offsite recovery publication is:

```text
create recovery point
-> verify locally
-> rclone copy/copyto-style publication
-> verify remote recovery point
-> report success
```

Pruning/deletion is a separate explicit operation. Normal publication must not use destructive `rclone sync` semantics.

## Updates

Normal application updates are safe, explicit, and operator-driven:

```text
discover stable project release
-> resolve/stage/download/build before downtime
-> verify a pre-update recovery point
-> activate an immutable exact release
-> health-gate
-> roll back coherently when safe
```

Automated update checking/notification is desirable. Unattended application update apply is not the default.

Ubuntu host package updates are a separate workflow. Application recovery must not pretend to roll back apt/kernel changes, and the product must never auto-reboot.

## Explicit non-goals

Do not recreate Make-based orchestration, Postfix/local-MTA or queue/spool/dead-letter machinery, multiple backup tiers, broad helper libraries, generic Docker cleanup, migration compatibility, broad repair commands, Kubernetes/Swarm/HA, plugin/provider frameworks, storage abstractions, updater daemons, workflow engines, ORMs/databases, event buses, generic transaction frameworks, distributed locks, or a new monitoring stack.

The earlier UI/UX is a design reference; the earlier backend architecture is not a compatibility target.

## Operator surfaces

The supported human/operator surfaces include:

- `setup.sh` for normal first-run setup;
- `dashboard.sh` for supported day-2 interactive operation;
- `vwctl` for authoritative status, diagnostics, automation, and mutations;
- administrator documentation with exact steps, expected success, and troubleshooting/recovery guidance.

The dashboard must delegate mutations to `vwctl` rather than becoming a second implementation authority.

## Naming end state

Normal final product/repository surfaces must be release-neutral. Product-generation, branch-stage, beta, or phase labels must not remain in normal runtime/docs/file names. Genuine technical schema/archive format version numbers remain valid. The dedicated naming-cleanup workstream owns mass renaming; do not opportunistically rename the tree as part of unrelated work.

## Decision details

`docs/V2-DECISIONS.md` records the durable implementation decisions behind this boundary. Historical audit/prompt reports remain useful evidence but do not override this current product contract unless explicitly promoted by the human for a task.
