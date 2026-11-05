# P8S-A: disposable stopped-state read-only batch

Base v2: 8590d83c074174824df1256b68d5bc0b57f4e9ab. Host: vaultwarden-oci-7-vnic, Ubuntu 26.04 ARM64.

P8M RESTORED/0, P8N HOLD/0, P8O FOUNDATION/0, P8Q READONLY/0 and P8R REARMED/0 were observed on the new disposable VM. P8P remains BLOCKED/2 despite a real changed kernel boot ID. P8R succeeded after 129 focused tests and nine green CI jobs; its accepted private summary is /home/ubuntu/vwoci-acceptance/p8r-origin-rearm-20261105T210337Z-2487/summary.txt. P8R was a manual origin re-arm, not automatic cold-boot persistence.

This one-shot read-only gate requires original clean exact P8P/P8Q/P8R checkouts, pinned report, durable marker, kernel continuity, immutable installed release and twelve units, dedicated ext4 storage, historical SQLite SHA/full integrity, SOPS/Age, dormant services, Worker and timers, no Docker containers or TCP 80/443 listeners, CrowdSec INPUT bouncer and Cloudflare dual-stack filter. It reuses the previously accepted P8P protected-state snapshot/doctor and checks all 27 doctor IDs.

No consent input is needed for read-only checks. It cannot refresh the firewall, start Caddy/Vaultwarden, replay restore, change DNS/Worker, contact or mutate Box, enable timers, send mail, reboot or remove markers.

Outcome HOLD/0 means the local state is safe but external OCI/Cloudflare isolation remains unverified. BLOCKED/2 means do not auto-retry or repair; retain root-private logs. P8S-A never means production GO.

Use a newly pinned clean branch checkout after code/CI review, sudo -n and python3 -B. Private sanitized reports remain in /home/ubuntu/vwoci-acceptance/p8s-a-readonly-*/summary.txt. Never share Age keys, raw doctor, protected logs, credentials, OCIDs or IPs. Original Box remote bw-backup:bw-backup is forbidden for test writes/pruning. Retire unencrypted disposable ext4 after acceptance.