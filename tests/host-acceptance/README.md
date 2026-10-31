# Ubuntu 26.04 ARM64 host-acceptance archive

These scripts and the [acceptance runbook](../../docs/PRODUCTION-ACCEPTANCE-UBUNTU2604.md) record the actual disposable Oracle Cloud ARM64 release acceptance of **0.1.0-rc.11** on Ubuntu 26.04. They are intentionally maintained alongside the codebase, rather than left on an inaccessible scratch branch.

**Historical, host-specific evidence, not a general installer or reusable automated test suite.** Many commands pin one test machine, disk-by-id, filesystem marker, Cloudflare development hostname, offline recovery public recipient and root Box folder. Some scripts can format an explicitly selected data disk, restore application data, modify Cloudflare Worker/DNS configuration, send real emails, publish backups or reboot. Do not run a historical command against another host, your live appliance, or a different remote. Never relax disk/recipient/retention checks simply to make an acceptance script pass.

The source baseline for this exercise was release **0.1.0-rc.11**, frozen at commit `e0f961c9093e98139e4f57bc94c49c9b79bbc386`. The preserved audit trail contains 23 numbered acceptance helpers (`01` through `23`, with gaps in numbering used as recovery/diagnostic subgates). For the exact sequence, constraints and evidence descriptions, read the linked runbook. The runbook records the original failures and accepted corrections, not only the final happy path.

## Verified operator outcomes (October 30–31, 2026 UTC)

- A0–A6: target Ubuntu ARM64 installation, original Box recovery verification, encrypted recovery-kit handoff, hardwired restore cancellation, and real disposable-host restore — PASS.
- B0/B1: Cloudflare-only Docker origin ingress, CrowdSec engine/Hub/host firewall, explicitly rearmed Cloudflare Worker with manual Fail Open verification, Caddy/Vaultwarden startup, DNS, one verified encrypted Box backup, and four active timers — PASS.
- C1: genuine reboot (changed kernel boot ID), preserved offline/operational Age and SOPS authority, intact restored SQLite, automatic app/timer startup, manual current-invocation Cloudflare Worker Fail Open, real HTTPS operational email and authenticated direct SMTP delivery tests — PASS.
- B2: actual unmodified 03:15 systemd backup timer firing on October 31 at 03:23:17 UTC, with a verified local recovery point, independent Box remote readback/checksum and zero automatic pruning — PASS.

**Release decision remains conditional.** These results establish the behavior of the frozen rc.11 runtime on the disposable VM, not that the corrected **rc.12** installer has passed a fresh Ubuntu 26.04 ARM64 deployment. The separately reviewed product-fix PR #373 targets the same protected release branch and addresses SOPS cross-filesystem atomic publishing and an explicit encrypted recovery-kit ZIP path. It must complete clean-image release validation before being declared production-ready.

The archived scripts are not installed by `setup.sh` and must not be automatically invoked by production systemd units. No private logs, Age private identities, decrypted SOPS values or authentication tokens belong in this directory.
