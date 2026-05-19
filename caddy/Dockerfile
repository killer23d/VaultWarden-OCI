# caddy/Dockerfile — VaultWarden-OCI
# Builds Caddy with:
#   - caddy-dns/cloudflare     (DNS-01 ACME challenge)
#   - caddy-cloudflare/caddy-cloudflare-ip      (real IP extraction from Cf-Connecting-Ip)
#   - mholt/caddy-ratelimit    (native per-IP rate limiting)
FROM caddy:2.11.2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/caddy-cloudflare/caddy-cloudflare-ip \
    --with github.com/mholt/caddy-ratelimit

FROM caddy:2.11.2-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
