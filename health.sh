fix(health): validate DOMAIN not DOMAIN_NAME in required_vars

DOMAIN_NAME was removed from .env.example as part of the single-source-of-truth
fix (derived at runtime from DOMAIN in caddy/entrypoint.sh). The health check
required_vars list still referenced DOMAIN_NAME, causing a false-positive
"Missing DOMAIN_NAME" warning on every clean install. Changed to DOMAIN.