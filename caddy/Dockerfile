# caddy/Dockerfile — VaultWarden-OCI
# Builds Caddy with:
#   - caddy-dns/cloudflare             (DNS-01 ACME challenge)
#   - WeidiDeng/caddy-cloudflare-ip    (real IP extraction from CF-Connecting-IP)
#   - fvbommel/caddy-combine-ip-ranges (combines Cloudflare IP ranges for trusted_proxies)
#   - mholt/caddy-ratelimit            (native per-IP rate limiting)
FROM caddy:2.11.2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/WeidiDeng/caddy-cloudflare-ip \
    --with github.com/fvbommel/caddy-combine-ip-ranges \
    --with github.com/mholt/caddy-ratelimit

FROM caddy:2.11.2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
