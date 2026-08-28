# Development

VaultWarden-OCI favors explicit ownership over frameworks. Python 3.12 standard-library-first owns structured behavior; Bash remains thin bootstrap/UI/host glue where materially simpler.

## First-party owners

- `vaultwarden_oci/cli.py` — base `vwctl` parsing, diagnostics, and dispatch.
- `vaultwarden_oci/install.py` — immutable installed layout.
- `vaultwarden_oci/storage.py` — dedicated-volume selection, identity, mount/boot guard.
- `vaultwarden_oci/runtime.py` — config parsing, runtime rendering, lifecycle/status/logs.
- `vaultwarden_oci/secrets.py` — SOPS/Age custody and volatile secret materialization.
- `vaultwarden_oci/setup.py` — authoritative setup CLI grammar, blank-VM installation orchestration, and setup-time host dependency ownership, including the minimal Age bootstrap required before transient offline-recovery generation.
- `vaultwarden_oci/setup_frontend.py` — thin first-run human wrapper for use-latest confirmation and transient offline-recovery/recovery-kit custody; it must derive custody decisions from the authoritative `setup.py` parser rather than interpreting raw argv independently.
- `vaultwarden_oci/edge.py` — Cloudflare origin policy and CrowdSec Cloudflare remediation.
- `vaultwarden_oci/recovery.py` / `recovery_ux.py` — `.vwrec`, rclone, guided restore, recovery-kit flow.
- `vaultwarden_oci/notification.py` — closed provider catalog rendering/delivery and bounded SMTP fallback.
- `vaultwarden_oci/update*.py` — exact version discovery/freezing and explicit immutable update transaction.
- `vaultwarden_oci/day2.py` / `dashboard.py` — read-only aggregation and supported presentation; no mutation ownership.
- `email-providers.toml` — immutable closed notification metadata.
- `versions.toml` — exact release/component/image authority.

`setup.sh` and `dashboard.sh` are supported human interfaces but not alternate state owners. Mutations converge on the same Python/`vwctl` owners. The setup frontend may decide whether the supported transient custody handoff is needed, but it does not own storage, installation, package selection, SOPS, recovery-kit cryptography, or notification transport. If terminal-generated custody requires `age-keygen` on a blank host, the frontend delegates that prerequisite to the setup-owned dependency helper before generating any private identity.

## Design invariants

Production state requires dedicated storage. `--use-latest` resolves once to exact immutable values. SOPS/Age operational/offline identities stay separate. `.vwrec` and recovery-kit ZIP stay separate. Caddy trusted-proxy trust and host origin filtering stay separate. CrowdSec remediates through Cloudflare. `/admin` keeps only the small token + rate limit + outer gate stack. Application updates remain recovery-gated/operator-driven; Ubuntu package updates are separate and never auto-reboot.

For first-run custody, `--auto` means automatic installation steps, not permission to invent unsafe headless key custody. With a TTY and no `--offline-recipient`, the frontend may generate the offline identity only in protected volatile storage and hand it off through the existing verified recovery-kit owner. With no TTY, a public recipient is required before installation mutation. Any explicitly supplied recipient is authoritative and must pass unchanged to `setup.main()`. Do not test value-option presence with exact raw-token membership: split (`--offline-recipient value`), equals (`--offline-recipient=value`), and any parser-supported long-option form must have the same meaning in frontend and installer.

A clean-host terminal-generated custody path must not assume Age tooling is preinstalled. The setup owner may install/verify only the prerequisite Ubuntu `age` tooling needed to create the transient identity before dedicated-storage provisioning; failure of that bootstrap must occur before private-identity generation and before data-device provisioning. Do not move package-install commands into the frontend or add project cryptography as a workaround.

The release source has one systemd owner: canonical `systemd/`. Direct source-layout update compatibility is tested only against the explicitly supported predecessor release. The public updater does not expose arbitrary intermediate-release selection, so older unsupported development snapshots are not promised an incremental-hop workflow; they require a fresh supported install/recovery path unless a deliberate transition is implemented. A narrowly constrained installed-release reader may exist only when required to recover from the supported predecessor's already-materialized immutable layout; it must not reintroduce a second repository/source owner.

Do not introduce a Postfix/queue, dynamic plugin/provider registry, storage abstraction, generic updater framework/daemon, broad repair engine, compatibility reader for an earlier archive format, ORM/database/event bus, HA/Kubernetes/Swarm layer, or second dashboard backend without an explicit product decision.

## Provider-catalog maintenance

For an existing provider endpoint/auth/request/success/retry change, re-check official provider documentation, edit the smallest `email-providers.toml` block, update focused tests/docs, and leave Python unchanged when the closed schema already expresses the behavior. Operator config cannot define arbitrary transport behavior.

Canonical message fields remain exactly `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`. Current CyberPersons policy is `503` status-only transient; `429` and `500 send_failed` are not transient by status alone.

## Validation

Permanent validation has three layers only:

1. focused unit tests under `tests/`;
2. small deterministic integrations, including Caddy config, recovery crypto/ZIP, and packet-boundary checks;
3. disposable Ubuntu 24.04 real-host acceptance on `amd64` and `arm64` where environments are available.

Tests protect security, availability, recoverability, and operator truthfulness rather than private source order/text. Do not create a custom runner, coverage gate, giant matrix, or duplicate test architecture.

Setup/custody changes must include regression coverage for terminal `--auto` generation without a recipient, explicit-recipient preservation in both split and equals value forms, parser-supported abbreviation behavior where applicable, complete headless failure before `storage.provision()`, blank-host Age bootstrap before private-key generation/storage provisioning, bootstrap failure before private-key generation, and transient-key cleanup only after successful recovery-kit handoff.

Local core checks mirror CI:

```bash
python3 -m compileall -q vaultwarden_oci tests
bash -n setup.sh dashboard.sh vaultwarden_oci/dashboard.sh tests/acceptance_edge_packet.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Real-host acceptance is described in [HOST-ACCEPTANCE.md](HOST-ACCEPTANCE.md) and must be reported honestly as `NOT RUN` when unavailable.

## Release workflow

1. Start from the current release branch/head and read `AGENTS.md`, `docs/PROJECT-BOUNDARY.md`, and `docs/DECISIONS.md`.
2. Change the smallest existing owner; do not create a parallel authority.
3. Run proportional unit/integration validation and inspect secret/security boundaries.
4. For release candidates, run disposable real-host acceptance on both supported architectures where environments are available and record unavailable coverage as `NOT RUN`.
5. Review the complete diff for stale generation/stage naming, duplicate logic, boot-volume fallback, parser/frontend disagreement, explicit-recipient override risk, and reintroduced non-goals.
6. Open a reviewable PR; do not self-merge unless the human explicitly instructs it.

Normal product/repository surfaces are release-neutral. Genuine schema, recovery-format, OCI/Docker protocol, semantic component, and immutable project release values remain technical compatibility identifiers and must not be cosmetically rewritten.
