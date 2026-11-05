# P8S-C: independent OCI/Cloudflare proof required before live canary

Base integration SHA: 8590d83c074174824df1256b68d5bc0b57f4e9ab.

Status HOLD, not accepted: repository inspection alone cannot verify authoritative OCI and Cloudflare provider state.

OCI checklist: independently verify the new disposable instance and attached VNIC identities; public IPv4; all attached NSGs plus effective subnet security lists and union of their ingress allowances; denial of TCP 80 unless separately approved; 443 restricted to approved Cloudflare CIDRs; absence of unintended public IPv6 ingress; serial-console recovery actually usable; original production VM remains isolated. Keep OCIDs and addresses private.

Cloudflare/DNS checklist: independent test hostname that does not collide with bw.lazymocha.com or original restored VM; authoritative DNS and wildcard checks; Worker route/custom-domain precedence; no production Worker Route overlap; proof the original production DNS/Worker/DDNS/SMTP/Box accounts are unchanged; test-only TLS and credentials.

Neither a passing DOCKER-USER rule nor self-attestation establishes external isolation. Until these provider observations are independently reviewed, all Caddy/Vaultwarden live startup, Worker, DNS and ACME actions remain forbidden.

Before future writable canary work, use a separate isolated test dataset and independent backup destination, not recovered user SQLite or historical bw-backup:bw-backup. Subsequent conditional stages: P8T live canary, P8U separate Worker policy, P8V isolated offsite, P8W timers/notifications, P8X recovery and final release reconciliation. No production GO.