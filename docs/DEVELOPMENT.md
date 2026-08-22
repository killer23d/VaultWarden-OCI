# Development

VaultWarden-OCI favors explicit ownership over frameworks. Python 3.12 standard-library-first owns structured behavior; Bash remains thin bootstrap/UI/host glue where materially simpler. The earlier product is a UI/UX, security, and behavior reference, not a backend compatibility target.

## First-party ownership

Current structured owners include:

- `vaultwarden_oci/cli.py` — base `vwctl` parsing, diagnostics, and command dispatch;
- `vaultwarden_oci/install.py` — immutable installation/layout machinery;
- `vaultwarden_oci/runtime.py` — config parsing, rendered runtime, lifecycle/status/logs;
- `vaultwarden_oci/secrets.py` — SOPS/Age custody and volatile secret materialization;
- `vaultwarden_oci/edge.py` — host-level Cloudflare origin policy and CrowdSec Cloudflare remediation;
- `vaultwarden_oci/recovery.py` — `.vwrec` recovery and rclone publication/pruning;
- `vaultwarden_oci/notification.py` — closed catalog renderer, HTTPS delivery, bounded retry, transient SMTP fallback;
- `vaultwarden_oci/update_versions.py`, `update.py`, `update_cli.py` — exact version resolution and explicit immutable application update transactions;
- `email-providers.toml` — immutable closed operational-notification metadata;
- `versions.toml` — exact release/version manifest.

The approved human surfaces are `setup.sh` for first-run setup and `dashboard.sh` for day-2 operation. They remain thin orchestration/presentation layers and delegate structured mutations to `vwctl`; they are not permission to duplicate Python state logic in Bash.

## Product invariants implementation must converge on

Future implementation work must preserve these durable decisions:

- production persistent application state is on a dedicated filesystem/volume, never a root-filesystem fallback;
- `setup.sh` supports interactive mode, `--auto`, and independent `--use-latest`;
- `--use-latest` resolves once to exact immutable versions/digests and leaves no floating `latest` state;
- `dashboard.sh` is supported, while `vwctl` remains the mutation authority;
- SOPS + Age uses a root-only operational identity and a separate offline recovery identity not persisted on-server;
- recovery-kit ZIP and `.vwrec` application recovery are separate artifacts;
- Caddy uses exact-pinned Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP, combined Cloudflare range, and rate-limit modules;
- Caddy's trusted-proxy module owns client-IP trust; do not generate a static Cloudflare `trusted_proxies` CIDR block as a second authority;
- host-level Cloudflare-only origin filtering remains a separate fail-closed `DOCKER-USER` control;
- CrowdSec web remediation remains Cloudflare-side without a required host firewall bouncer;
- `/admin` retains the admin token, Caddy-side rate limiting, and one simple outer authentication gate;
- normal application updates are operator-driven and recovery-gated; Ubuntu package updates are separate and never auto-reboot.

## Provider-catalog maintenance

For routine upstream changes to an existing built-in provider—endpoint, auth metadata, request shape, success rule, retry classification, or a representable non-secret option:

1. re-check current official provider documentation;
2. edit only the relevant block in `email-providers.toml` when the existing schema can represent the change;
3. update the smallest focused notification tests;
4. update operator/security documentation only where behavior or setup changed;
5. run the focused catalog/security validation.

Change Python only when the provider requires a genuinely new transport capability that cannot be represented safely by the existing closed schema. Do not generalize the catalog into arbitrary operator-defined endpoints/auth/payloads.

The canonical message fields remain exactly:

```text
from_email
from_name
from_header
to_email
subject
text
```

For CyberPersons, preserve current implemented/catalog behavior unless a focused change deliberately re-verifies official docs: `503` is status-only transient; `429` and `500 send_failed` are not transient by status alone.

## Caddy maintenance

Caddy remains an xcaddy custom build. The useful earlier build is a behavior/module reference, not an architecture to copy wholesale.

The required module capabilities are:

- Cloudflare DNS;
- Cloudflare trusted-proxy/real-client-IP;
- combined Cloudflare IP ranges;
- Caddy rate limiting.

All must be exact-pinned through the release/version authority. Avoid two independent real-client-IP sources: after the trusted-proxy module owns Cloudflare trust, remove generated static trusted-proxy CIDR injection from Caddy while retaining the separate host `DOCKER-USER` Cloudflare source-range filter.

## Setup/dashboard implementation discipline

`setup.sh` may perform simple shell-host work and interactive prompting, but structured validation/version/config/secrets operations should call the Python owners. `dashboard.sh` may render state and menus but should invoke `vwctl` for mutations.

The earlier AMTM-style/color-coded interface is a design reference. Do not copy the earlier Make orchestration, Postfix/queue machinery, broad helper libraries, backup tiers, migration behavior, or generic repair framework to recreate that UX.

## Recovery implementation discipline

There is one `.vwrec` application recovery format. The human local/remote picker and explicit CLI restore forms feed the same recovery implementation.

The separate recovery-kit ZIP uses AES-256 with an interactively entered/confirmed independent passphrase. Never add an argv/env/file passphrase shortcut. Verify the encrypted ZIP fully before email handoff.

## Update implementation discipline

The current pinned update transaction already contains useful safety properties: pre-update health gate, verified recovery point, staging/build before activation, immutable release switch, post-activation health gate, and conservative rollback behavior when persistent state may have changed.

Extend toward stable project-release discovery and optional automatic check/notification without creating an updater daemon or making unattended apply the default.

Ubuntu apt/kernel maintenance is a separate workflow and must never be represented as application rollbackable. Never auto-reboot.

## Validation

Use three permanent layers:

1. focused unit tests;
2. small integration tests;
3. disposable Ubuntu 24.04 host acceptance on `amd64`/`arm64` where environments are available.

Do not turn full-host acceptance into a permanent per-PR controller, and do not couple tests to private source strings/order solely to freeze implementation shape.

For a docs-only contract change, inspect the complete diff/cross-links and run focused contradiction searches. Broad runtime testing is unnecessary unless repository enforcement requires it.

## Release workflow

1. start from current `v2` and confirm its exact head;
2. read the durable product boundary/decisions before changing architecture;
3. make the smallest coherent change in the existing owner;
4. run proportional validation and record what was not run;
5. inspect for secret leakage, duplicate authorities, V1-backend reintroduction, and accidental frameworks;
6. open a PR to `v2`; do not self-merge unless explicitly instructed.

## Release-neutral naming

The final normal product/repository surface must not retain product-generation, branch-stage, beta, or phase labels in normal runtime/docs/file names. Genuine technical schema/archive format versions remain valid.

Mass naming cleanup belongs to its dedicated workstream. Other changes should avoid creating new stage-labelled surfaces but should not opportunistically mass-rename the current tree.

## Current implementation gaps

The durable contract intentionally runs ahead of several current implementation details: dedicated-storage enforcement, `setup.sh`, `dashboard.sh`, operator-supported exact-freezing `--use-latest`, and the full required Caddy module/trusted-proxy design are not yet present on the current development branch. Treat these as bounded implementation work, not alternative architecture decisions.
