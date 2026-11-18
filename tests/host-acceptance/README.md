# Reusable host acceptance tools

**Current software-release tooling only.** These are not installed
appliance commands, and they are not a replacement for the supported
`setup.sh`, `vwctl`, or the complete
[Host acceptance](../../docs/HOST-ACCEPTANCE.md) checklist.

| Tool | Appropriate target | Effect |
| --- | --- | --- |
| `production-new-host-preflight.py` | New blank-data Ubuntu 26.04 ARM64 candidate, exact reviewed source commit | Read-only version/source/host/boot-disk/blank-volume inventory and private evidence; no format or installation consent |
| `production-readiness-inventory.py` | Explicitly selected already-installed appliance host | Read-only installed version, storage/custody, doctor/timers/status and private evidence; do not use for a blank VM |

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

For the present rc.13 release, the earlier recovered-data VM is
a protected reference fixture. A separate blank-data test VM has
completed P0 and the supported P1 installer dry run only;
installation, external packet security and test-only restore remain
unrun until scoped authorization.
