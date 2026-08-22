# Development

V2 favors explicit ownership over frameworks. Structured behavior belongs in Python 3.12 standard-library modules, Bash is minimal glue, provider metadata is data, and the permanent test suite is Python `unittest` plus a few bounded integration scripts.

## First-party ownership

- `vaultwarden_oci/cli.py` — base `vwctl` parsing, diagnostics, and command dispatch.
- `vaultwarden_oci/install.py` — immutable installation/layout.
- `vaultwarden_oci/runtime.py` — config parsing, rendered runtime, lifecycle/status/logs.
- `vaultwarden_oci/secrets.py` — SOPS/Age custody and volatile secret materialization.
- `vaultwarden_oci/edge.py` — Cloudflare origin policy and CrowdSec Cloudflare remediation.
- `vaultwarden_oci/recovery.py` — V2 recovery and rclone publication/pruning.
- `vaultwarden_oci/notification.py` — closed catalog renderer, HTTPS delivery, bounded retry, transient SMTP fallback.
- `vaultwarden_oci/update_versions.py`, `update.py`, `update_cli.py` — exact pins and explicit immutable updates.
- `email-providers.toml` — immutable closed metadata for six operational email providers.
- `versions.toml` — one release/version manifest.
- `systemd-v2/` — installed V2 units.
- `tests/v2/` — permanent automated tests and bounded integration probes.

Do not revive V1 wrapper scripts, dashboard/TUI ownership, migration readers, Postfix queue tooling, custom test-runner frameworks, provider SDKs, or general HTTP/plugin scripting.

## Provider-catalog maintenance

For routine upstream changes to an existing built-in provider—endpoint, supported auth metadata, request shape, success rule, retry statuses/delay semantics, or a representable non-secret option:

1. Re-check the provider's current official documentation.
2. Edit only the relevant block in `email-providers.toml` when the existing catalog schema can represent the change.
3. Update the smallest focused tests in `tests/v2/test_notification.py` and/or `test_notification_security.py`.
4. Update operator/security documentation only where behavior or setup changed.
5. Run the V2 suite and catalog/security tests.

Change Python only when the provider now requires a **genuinely new transport capability** that cannot be represented safely by the existing closed schema. Do not add provider-specific Python merely because upstream metadata changed, and do not generalize the catalog into arbitrary operator-defined endpoints/auth/payloads.

The canonical message fields are fixed: `from_email`, `from_name`, `from_header`, `to_email`, `subject`, `text`.

## Local validation

On Ubuntu 24.04 or another suitable development environment with Python 3.12:

```bash
python3 -m compileall -q vaultwarden_oci tests/v2
python3 -m unittest discover -s tests/v2 -p 'test_*.py' -v
bash -n bootstrap-v2.sh tests/v2/acceptance_edge_packet.sh
```

The recovery crypto acceptance additionally requires `age`, `age-keygen`, and `sops`:

```bash
python3 tests/v2/acceptance_recovery_crypto.py
```

The edge packet acceptance is Linux/root/Docker/network-namespace destructive test glue and belongs on a disposable Ubuntu 24.04 host or dedicated runner:

```bash
sudo tests/v2/acceptance_edge_packet.sh
```

Do not turn full host acceptance into a per-PR controller. Use [HOST-ACCEPTANCE.md](HOST-ACCEPTANCE.md) as the release gate.

## CI

Permanent CI should stay at three layers:

1. syntax/compile and shell parse checks;
2. the V2 Python unit/small integration suite;
3. bounded integration tests only where the runner has the explicit prerequisites.

Full install, external Cloudflare/CrowdSec/provider/rclone behavior, destructive restore, and multi-architecture host acceptance are release-gate evidence, not something to emulate with an ever-growing mock orchestration framework.

## Development-only latest resolution

Production never uses mutable latest values. For isolated development/testing only, `--use-latest` requires an explicit boundary and must not target `/`:

```bash
sudo env VWOCI_DEVELOPMENT=1 ./vwctl install \
  --source "$PWD" --use-latest --root /tmp/vwoci-dev-root
```

The resolver looks up each latest component/image boundary once, freezes exact values/digests, and records them for that run. Do not carry `--use-latest` into production documentation or release automation.

## Release workflow

1. Start from current `v2`; review decisions/test strategy before changing architecture.
2. Make the smallest coherent change. If immutable release content changes, bump `[vaultwarden_oci].version` in `versions.toml`.
3. Run permanent tests and focused validations.
4. Run the disposable-host acceptance matrix where environments are available (`amd64`, `arm64`). Record anything not run.
5. Review the diff for secret leakage, provider/catalog endpoint authority, V1 surface reintroduction, and mixed-responsibility files.
6. Open a PR to `v2`; do not self-merge unless explicitly instructed.

Use `vwctl --help` as the command reference. If a command changes, update workflow docs/tests rather than regenerating a second manual.
