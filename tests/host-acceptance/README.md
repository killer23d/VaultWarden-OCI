# Reusable host acceptance tools

**Current software-release tooling only.** These are not installed
appliance commands, and they are not a replacement for the supported
`setup.sh`, `vwctl`, or the complete
[Host acceptance](../../docs/HOST-ACCEPTANCE.md) checklist.

**rc.13 disposable-host P2/P3 audit:** The guarded G9A/G9C and
G11B-G11G one-shot scripts were tied to a single disposable VM,
immutable installed source and exact private-data/remote object pins.
Their operator-reported outcomes and immutable source-commit links are
archived **in one place** under
[Host acceptance, P3 provenance](../../docs/HOST-ACCEPTANCE.md#p3-one-shot-audit-provenance-historical-not-active-replay-tools).
The eight executed source scripts are intentionally **not retained as
active runnable tests** after this PR. G9B/G11F perform destructive
restores; never reuse an archived command on a live appliance or against
historical Box objects. Preserve acceptance evidence, not duplicated
infrastructure automation. Permanent, reusable regression coverage
remains in `tests/test_*.py`, targeted integration tests and CI.

| Tool | Appropriate target | Effect |
| --- | --- | --- |
| `production-new-host-preflight.py` | New blank-data Ubuntu 26.04 ARM64 candidate, exact reviewed source commit | Read-only version/source/host/boot-disk/blank-volume inventory and private evidence; no format or installation consent |
| `production-readiness-inventory.py` | Explicitly selected already-installed appliance host | Read-only installed version, storage/custody, doctor/timers/status and private evidence; do not use for a blank VM |
| `dashboard-console.py` | Explicitly selected installed appliance with its exact reviewed source | Verify immutable release and units, then bounded exit/default-no terminal paths; no operation approval |
| `guided-recovery-preflight.py` | Explicitly selected installed ARM64 appliance with a clean exact installed-source checkout | Reuse the checksum-verified immutable verifier, inspect current protected baseline and print a sanitized read-only receipt; no candidate adoption, remote access, identity extraction, scheduling change or restore |

Permanent source-level and integration acceptance for the software
lives in `tests/test_*.py`, `tests/acceptance_*.py`,
`tests/acceptance_edge_packet.sh` and GitHub CI. The software
release checklist remains in
[Host acceptance](../../docs/HOST-ACCEPTANCE.md) and
[Development](../../docs/DEVELOPMENT.md#software-release-readiness-versus-site-deployment).

**Historical archive:** all original numbered ARM64 one-shots, the
disposable restored-host scripts and P8M–P8V OCI/Cloudflare
investigations (and their script-specific tests) are recorded in
[Historical infrastructure acceptance](../../docs/HISTORICAL-INFRASTRUCTURE-ACCEPTANCE.md).
The exact original files remain retrievable via the pre-consolidation
commit linked there. **Do not replay them:** some mutate disks,
cloud provider policies, mail, backup remotes or reboot.

For rc.13, the historical recovered-data VM remains a protected
reference fixture. A **separate blank-data disposable Ubuntu 26.04
ARM64 VM** completed P0/P1 and subsequently the supported P2 install,
real local/Caddy/Admin and isolated local/offsite encrypted recovery
gates through P3-G11G; the populated Box restore returned precisely
the original saved item and eliminated the post-backup test item.
Source was pinned to `fd56313255c97992dc55c1475d94477597b88602`;
later docs-only commits do not retroactively establish live-host results
against a different release source. The operator additionally reported
Admin/Caddy/restore working, a scoped manual smoke rather than a full
browser/SMTP mailbox acceptance. External origin-denial packet testing,
reboot/timer/Worker re-arm, and applicable upgrade/initial-custody
variants are still separate gates or explicit NOT RUN limitations.
This acceptance is **not production release GO**.
