# VaultWarden-OCI V2 beta

VaultWarden-OCI V2 is a small, opinionated Vaultwarden deployment for a single Ubuntu 24.04 host. The beta is cloud-neutral at the host/runtime layer, uses OCI images, and treats Cloudflare as the supported public-edge reference. It intentionally has no V1 compatibility layer, dashboard/TUI, Postfix queue, provider plugin framework, or generated command manual.

## Beta contract

- Ubuntu 24.04 LTS on `amd64` or `arm64`.
- Python 3.12 standard-library code owns structured logic; Bash is limited to the bootstrap and test glue.
- One operator command: `vwctl`.
- One operator config: `/etc/vaultwarden-oci/config.toml`.
- One release version manifest: `versions.toml`, with exact production component/image pins.
- SOPS + Age protect credentials with distinct operational and offline-recovery identities. Decrypted values are transient; runtime secret files live under `/run/vaultwarden-oci`.
- Vaultwarden application email goes directly to authenticated TLS SMTP.
- Operational notifications use one of six closed built-ins: `mailersend`, `sendgrid`, `mailgun`, `postmark`, `resend`, or `cyberpersons`; `cyberpanel` is an alias for `cyberpersons`. SMTP is a transient-only fallback after a clearly transient API/network failure.
- Recovery uses one V2 Age-encrypted `.vwrec` format. Offsite publication is local verify -> `rclone copyto` -> remote re-download/verify -> success. Retention pruning is a separate explicit operation.
- Public HTTPS origin ingress is restricted to validated/bounded Cloudflare ranges and fails closed when no safe current/last-known-good policy exists.
- CrowdSec web decisions are remediated through Cloudflare in beta. A host firewall bouncer is not part of the supported beta architecture.
- Production updates activate exact pinned releases. `--use-latest` exists only behind an explicit isolated development/test boundary.

The detailed architectural decisions remain in [docs/V2-DECISIONS.md](docs/V2-DECISIONS.md) and [docs/PROJECT-BOUNDARY.md](docs/PROJECT-BOUNDARY.md).

## Start here

1. Read [docs/INSTALL.md](docs/INSTALL.md) and prepare a disposable or production Ubuntu 24.04 host with Docker Engine + Compose, Age, SOPS, rclone, `iptables`/`ip6tables`, and outbound connectivity required by your chosen providers.
2. From a trusted checkout of the `v2` branch/release, install the immutable layout:

   ```bash
   sudo ./bootstrap-v2.sh
   ```

3. Configure `/etc/vaultwarden-oci/config.toml`, create distinct operational/offline Age identities, and encrypt `/etc/vaultwarden-oci/secrets.sops.yaml` to both recipients as described in the install guide.
4. Validate and start:

   ```bash
   sudo vwctl config validate --file /etc/vaultwarden-oci/config.toml
   sudo vwctl start
   sudo vwctl status
   sudo vwctl doctor --json
   ```

5. When the normal lifecycle is healthy, enable the V2 systemd target and timers:

   ```bash
   sudo systemctl enable --now vaultwarden-oci.target
   ```

`vwctl --help` and subcommand `--help` output are the command reference. The docs show workflows and invariants rather than duplicating a generated manual.

## Documentation

- [INSTALL](docs/INSTALL.md) — host prerequisites, immutable layout, operator TOML, SOPS/Age custody, Cloudflare/CrowdSec bootstrap, and CyberPanel Email/CyberPersons setup.
- [OPERATIONS](docs/OPERATIONS.md) — status, doctor JSON, logs, systemd automation, edge refresh, versions, and explicit updates.
- [SECURITY](docs/SECURITY.md) — trust boundaries, secret handling, fail-closed ingress, notification/catalog security, and unsupported surfaces.
- [RECOVERY](docs/RECOVERY.md) — encrypted recovery creation, rclone publication, restore, offline identity use, and explicit pruning.
- [DEVELOPMENT](docs/DEVELOPMENT.md) — code ownership, provider-catalog maintenance, tests, CI, and release workflow.
- [HOST ACCEPTANCE](docs/HOST-ACCEPTANCE.md) — disposable Ubuntu 24.04 release-gate procedure for `amd64`/`arm64` where environments are available.

## Runtime ownership

The installed release is immutable under `/opt/vaultwarden-oci/releases/<version>` with `/opt/vaultwarden-oci/current` selecting the active release and `/usr/local/bin/vwctl` pointing at the active CLI. Operator configuration and encrypted credentials live under `/etc/vaultwarden-oci`; durable data/recovery state lives under `/var/lib/vaultwarden-oci`; generated runtime material and decrypted secret files live under `/run/vaultwarden-oci`.

The source of truth is deliberately compact: `vaultwarden_oci/` owns runtime behavior, `systemd-v2/` owns the installed units, `email-providers.toml` owns closed operational-email metadata, `versions.toml` owns release pins, and `tests/v2/` owns permanent automated coverage.

## Beta acceptance

Permanent pull-request CI is intentionally smaller than full host validation: Python quality/unit tests plus bounded recovery-crypto and edge-packet integration checks. Destructive/full-host behavior is a release gate on disposable Ubuntu 24.04 hosts, not a giant per-PR controller. See [docs/HOST-ACCEPTANCE.md](docs/HOST-ACCEPTANCE.md).

Old V1 scripts, systemd units, migration readers, Postfix/dashboard tooling, generated command reference, and V1 test architecture are not shipped on `v2`; use `main` or Git history for the retired implementation.
