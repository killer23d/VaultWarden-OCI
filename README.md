# VaultWarden-OCI

VaultWarden-OCI is a small, opinionated Vaultwarden appliance for roughly 10 users, designed to be operable by a junior administrator and mostly set-and-forget. It supports Ubuntu 24.04 LTS on `amd64` and `arm64`, is cloud-provider neutral at the host/runtime layer, and uses Cloudflare as the supported public-edge model.

The earlier product remains a deliberate UI/UX, security, and behavior reference. Its backend architecture is not a compatibility target.

## Product contract

- Production persistent application state lives on a dedicated filesystem/volume, never only on the boot/root filesystem.
- `setup.sh` is the normal first-run experience: validate host/storage, install dependencies and appliance content, prepopulate operator config, assist secrets/recovery custody, then leave an explicit config/secrets -> start path.
- `setup.sh` supports interactive mode, `--auto`, and an independent explicit `--use-latest`. When requested, `--use-latest` resolves once to exact immutable versions/digests; floating `latest` state is never retained.
- `dashboard.sh` is a supported day-2 human interface using the useful color-coded/AMTM-style interaction conventions of the earlier product.
- `vwctl` remains the implementation and mutation authority. Human interfaces delegate mutations to it rather than creating a second state owner.
- Python 3.12 standard-library-first owns structured config/state/validation/update/recovery logic; Bash stays thin bootstrap/UI/host glue where materially simpler.
- One operator-editable non-secret config authority under `/etc/vaultwarden-oci`, one encrypted SOPS secret document, and one source-controlled exact version manifest.
- SOPS + Age protects secrets. The operational Age private key is root-only; the separate offline recovery private identity is not persistently stored on the server.
- Vaultwarden application email uses direct authenticated SMTP. Operational notifications use the existing closed source-controlled provider catalog.
- One encrypted `.vwrec` application recovery format is supported. A password-protected AES-256 recovery-kit ZIP is a separate credential-handoff artifact.
- Caddy is an exact-pinned xcaddy build with Cloudflare DNS, Cloudflare trusted-proxy/real-client-IP support, combined Cloudflare ranges, and Caddy rate limiting.
- Caddy's Cloudflare trusted-proxy module owns real-client-IP trust. A separate small fail-closed Docker `DOCKER-USER` path restricts published HTTPS origin traffic to validated Cloudflare source ranges.
- CrowdSec remediates proxied web-client decisions through Cloudflare; no CrowdSec host firewall bouncer is required.
- `/admin` retains defense in depth: Vaultwarden admin token, Caddy-side rate limiting, and one simple outer authentication gate.
- Application updates are explicit and operator-driven: discover a stable release, stage/download/build before downtime, verify a pre-update recovery point, activate an immutable exact release, health-gate, and roll back coherently when safe. Unattended apply is not the default.
- Ubuntu package updates are a separate workflow; application recovery does not claim to roll back apt/kernel changes, and the appliance never auto-reboots.

See [docs/PROJECT-BOUNDARY.md](docs/PROJECT-BOUNDARY.md) and [docs/V2-DECISIONS.md](docs/V2-DECISIONS.md) for the durable contract.

## Normal administrator path

The supported production path is:

```text
prepare Ubuntu 24.04 + dedicated storage
-> run setup.sh
-> review/complete config and secrets
-> verify recovery custody
-> start with vwctl
-> operate with dashboard.sh and/or vwctl
```

After setup has completed and configuration/secrets are ready, the authoritative start/verification sequence is:

```bash
sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
sudo vwctl start
sudo vwctl status
sudo vwctl doctor --json
```

A doctor `FAIL` is not a successful install.

## Current development-branch implementation status

The durable contract above intentionally supersedes several older implementation decisions. At this synchronization point, the current development branch still has known implementation gaps: it exposes `bootstrap-v2.sh` rather than the approved `setup.sh` first-run flow, lacks the approved `dashboard.sh`, keeps persistent state under `/var/lib/vaultwarden-oci` without enforcing a separate storage filesystem, gates `--use-latest` as development-only, and renders static Caddy trusted-proxy CIDRs while building only the Cloudflare DNS xcaddy module.

Those are implementation gaps for later bounded workstreams, not reasons to narrow the product contract. `bootstrap-v2.sh` remains a low-level development/implementation bootstrap until the supported setup workflow is implemented; it is not a substitute for the final production installation contract.

## Documentation

- [INSTALL](docs/INSTALL.md) — supported host/storage requirements, first-run setup contract, config, SOPS/Age custody, and edge bootstrap.
- [OPERATIONS](docs/OPERATIONS.md) — dashboard/CLI day-2 operation, status/doctor/logs, systemd, edge, notifications, and updates.
- [SECURITY](docs/SECURITY.md) — trust boundaries, secrets, Caddy/origin separation, `/admin`, notification security, and unsupported surfaces.
- [RECOVERY](docs/RECOVERY.md) — `.vwrec` application recovery, guided/CLI restore, rclone publication, and separate recovery-kit custody.
- [DEVELOPMENT](docs/DEVELOPMENT.md) — implementation ownership, provider/Caddy maintenance, tests, and release workflow.
- [HOST ACCEPTANCE](docs/HOST-ACCEPTANCE.md) — disposable Ubuntu 24.04 release-gate procedure for `amd64` and `arm64` when environments are available.

## Durable ownership

The intended installed release is immutable under `/opt/vaultwarden-oci/releases/<version>` with `/opt/vaultwarden-oci/current` selecting the active release and `/usr/local/bin/vwctl` pointing to the active CLI. Operator configuration and encrypted credentials live under `/etc/vaultwarden-oci`; generated/decrypted runtime material lives under `/run/vaultwarden-oci`; persistent application/recovery state lives on the required dedicated production storage filesystem.

`vaultwarden_oci/` owns structured runtime behavior, `email-providers.toml` owns the closed operational-notification metadata, and `versions.toml` owns exact release pins. Supported Bash interfaces stay thin and delegate structured work to these owners.

Normal final product/repository names must be release-neutral. Existing product-generation, branch-stage, beta, and phase names are temporary implementation debt to be removed by the dedicated naming-cleanup workstream; this contract synchronization does not mass-rename them.
