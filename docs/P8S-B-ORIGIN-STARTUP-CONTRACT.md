# P8S-B: source contract for origin fail-closed startup

Base v2: 8590d83c074174824df1256b68d5bc0b57f4e9ab.

The installed default-path runtime.lifecycle(start/restart) refreshes origin policy before Docker Compose up. edge.refresh_origin_policy installs temporary both-family DOCKER-USER 443 drop guards before contacting the Cloudflare policy source or LKG. It builds IPv4 and IPv6 CIDR source allowlist chains with terminal DROP, installs jumps, and only then removes guards.

Caddy owns published 443 with restart no. Vaultwarden uses restart unless-stopped but is only on the internal Docker bridge. CrowdSec nftables bouncer owns host INPUT, not Docker FORWARD/DOCKER-USER.

New focused regression tests cover unsafe CIDRs, missing source and LKG, dual-stack firewall guard ordering, partial firewall failure, Compose startup ordering, IPv6 bridge settings and CrowdSec separation.

These are source/mocked tests, not real packet path or Docker daemon restart evidence. The current reboot milestone P8P remains BLOCKED and P8R proves explicit manual rearm only. Keep external OCI NSG, DNS, route overlap and live HTTPS marked HOLD.

Do not rewrite product firewall architecture solely for tests. Next network-namespace or disposable-host packet integration must not expose historical production identity, restored user data or original Box destination.