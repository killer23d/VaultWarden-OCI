# caddy/Dockerfile — VaultWarden-OCI
# Builds Caddy with:
#   - caddy-dns/cloudflare             (DNS-01 ACME challenge)
#   - WeidiDeng/caddy-cloudflare-ip    (real IP extraction from CF-Connecting-IP)
#   - fvbommel/caddy-combine-ip-ranges (combines Cloudflare IP ranges for trusted_proxies)
#   - mholt/caddy-ratelimit            (native per-IP rate limiting)
#
# CADDY_VERSION is passed from docker-compose build.args (sourced from .env).
# A single version variable controls both the builder and the final runtime
# image so they are always in sync.
# Do NOT set this to 'latest' — a reproducible xcaddy build requires a pinned
# upstream tag. Update the default here and in .env.example together.
ARG CADDY_VERSION=2.11.4

FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.4 \
    --with github.com/WeidiDeng/caddy-cloudflare-ip@f53b62aa13cb7ad79c8b47aacc3f2f03989b67e5 \
    --with github.com/fvbommel/caddy-combine-ip-ranges@v0.0.1 \
    --with github.com/mholt/caddy-ratelimit@v0.1.0

FROM caddy:${CADDY_VERSION}-alpine

# Dedicated non-root user for the Caddy runtime.
# UID/GID 2000 is reserved for Caddy across this project; do not reuse for
# other services. init-permissions chowns /data/caddy, /config/caddy, and
# the log files to this UID before Caddy starts.
RUN addgroup -g 2000 caddy && \
    adduser -D -u 2000 -G caddy caddy

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

# NET_BIND_SERVICE is granted at runtime via cap_add in docker-compose so
# Caddy can bind ports 80 and 443 without root. No setcap needed here.
USER caddy
