# P8S-A: disposable stopped-state read-only batch

Base integration SHA: 8590d83c074174824df1256b68d5bc0b57f4e9ab. Host: vaultwarden-oci-7-vnic, Ubuntu 26.04 ARM64.

P8M RESTORED/0, P8N HOLD/0, P8O FOUNDATION/0, P8Q READONLY/0 and P8R REARMED/0 were observed on the new disposable VM. P8P remains BLOCKED/2 despite a real changed kernel boot ID. P8R succeeded after 129 focused tests and nine green CI jobs; its accepted private summary is /home/ubuntu/vwoci-acceptance/p8r-origin-rearm-20261105T210337Z-2487/summary.txt. P8R was a manual origin re-arm, not automatic cold-boot persistence.

This one-shot read-only gate requires original clean exact P8P/P8Q/P8R checkouts, pinned report, durable marker, kernel continuity, immutable installed release and twelve units, dedicated ext4 storage, historical SQLite SHA/full integrity, SOPS/Age, dormant services, Worker and timers, no Docker containers or TCP 80/443 listeners, CrowdSec INPUT bouncer and Cloudflare dual-stack filter. It reuses the previously accepted P8P protected-state snapshot/doctor and checks all 27 doctor IDs.

No consent input is needed for read-only checks. It cannot refresh the firewall, start Caddy/Vaultwarden, replay restore, change DNS/Worker, contact or mutate Box, enable timers, send mail, reboot or remove markers.

Outcome HOLD/0 means the local state is safe but external OCI/Cloudflare isolation remains unverified. BLOCKED/2 means do not auto-retry or repair; retain root-private logs. P8S-A never means production GO.

Use a newly pinned clean branch checkout after code/CI review, sudo -n and python3 -B. Private sanitized reports remain in /home/ubuntu/vwoci-acceptance/p8s-a-readonly-*/summary.txt. Never share Age keys, raw doctor, protected logs, credentials, OCIDs or IPs. Original Box remote bw-backup:bw-backup is forbidden for test writes/pruning. Retire unencrypted disposable ext4 after acceptance.
## Corrective consolidation after first P8S-A run (November 5, 2026)

The first P8S-A candidate at commit 64546df42a2ea062a1008a9ae24398a07441fd8c was actually run on the NEW disposable host. It returned BLOCKED / P8S_A_EXIT=2 with the generic message "P8S-A evidence, protected state or read-only diagnostic failed". It never reached a reported HOLD and must **not** be classified as accepted. It performed no firewall refresh, app activation or offsite mutation. The exact underlying mismatch cannot be deduced from this generic console message.

A combined corrective PR incorporates P8S-B's source-level startup regression tests and P8S-C's independent isolation HOLD checklist. It repairs P8S-A's preflight diagnostic gap by creating a root-private report directory before the original historical evidence validation, and prints **only authored phase labels and allowlisted reason codes**. Unexpected exception strings, protected values and raw host logs are never printed. No historical marker is deleted, overwritten or replayed. A new clean checkout is required for the corrected candidate; never reuse or edit the original P8S-A checkout.

**One host turn:** from the consolidated PR's exact reviewed HEAD after all CI jobs pass, run the focused P8S-A/P8S-B Python tests, then the read-only P8S-A host batch. Capture the private summary and sanitized result only. The related P8S-C provider checks remain HOLD unless independently verified through OCI and Cloudflare. Do not start services based solely on a P8S-A pass.

## Corrected P8R terminal formatting (November 5, 2026)

The second real disposable-VM P8S-A invocation ran **20/20 focused regression tests PASS**, then reached the historical P8R summary check and returned **BLOCKED/2** at `prior.p8r-accepted-summary reason=history.p8r-summary-outcome`. Private diagnostic path was `/home/ubuntu/vwoci-acceptance/p8s-a-readonly-20261105T213303Z-3739/summary.txt`. The run did **not** reach snapshot/doctor or alter any service. This BLOCKED remains historical evidence, not a PASS.

The root cause is a **test-reader formatting bug**: the original P8R writer generates each final line with a ten-character left-aligned status **plus one separating space**. For `REARMED`, this results in four spaces before `P8R`; the original P8S-A reader incorrectly expected three. Its fixture duplicated the incorrect constant, so its tests falsely passed. The consolidated correction now matches original P8R writer formatting, uses an **independent literal source-writer fixture**, and asserts that the old three-space line is rejected. No P8R marker, historical report, or original production state was changed.

After all CI jobs pass, use **a fresh distinct checkout pinned to the corrected PR HEAD** to run the focused P8S-A/P8S-B suites and read-only host preflight in one invocation. Do not edit the original failed checkouts, rerun P8R, or begin live/Box/Worker activity. A `HOLD/0` means stopped-host checks passed but external isolation remains unverified.
