# P8 isolation acceptance and first live start boundaries

Status: **P8A accepted READ-ONLY HOLD/exit 0** on 2026-11-04 after **115 focused tests passed** on the original disposable host, from exact reviewed commit `697c9b84ce73c17ebb4789c2c12c7cc5d95b2deb`. Local integrity/security and all nine PR CI checks passed; 13 generated/volatile runtime paths remain absent with zero unsafe paths. External OCI/Cloudflare isolation, original offline custody and test-only Box prefix remain PENDING. **No live startup or production cutover is approved.**

## What P7 and P7R proved

P7 rebooted the disposable rc.12 Ubuntu 26.04 ARM64 host while the application stayed stopped. Protected data, SOPS/Age, SQLite, dedicated storage and enabled CrowdSec survived. The Docker Cloudflare-only TCP/443 policy did **not** persist; the correct result remains HOLD. P7R separately and successfully invoked the installed product's origin-policy refresh once after that reboot and proved that the local rules were REARMED. Both gates are complete and must not be replayed. Current branch starts from release-branch commit `8590d83c074174824df1256b68d5bc0b57f4e9ab`.

## P8A operator procedure — read-only

Only run the exact PR-HEAD-pinned one-shot command supplied in the operator handoff on `ubuntu@vaultwarden-oci-6-vnic`. It clones a fresh checkout, verifies the exact commit and its cleanliness, runs focused mocked tests, then uses `sudo -n python3 -B -E tests/host-acceptance/production-p8-isolation-preflight.py --expected-commit <PR_HEAD>`. Evidence written: new root-private sanitized summary only, under `~/vwoci-acceptance/p8-isolation-preflight-*/summary.txt`. Do not paste raw doctor output, checkpoint JSON, private ZIP/key, SMTP/Cloudflare tokens or logs.

P8A checks current host identity, immutable rc.12/source/unit integrity, original volume/SQLite/SOPS/Age and hashes, P7 checkpoint/summary and P7R exclusive marker/accepted summary, five local security doctor checks and complete 27-check registry, current Cloudflare Docker ingress, CrowdSec INPUT bouncer, disabled Worker, stopped app/DNS/four timers, no Docker containers or HTTP listeners, zero Box age retention, SMTP TLS validation, admin pairing, generated path ownership/symlink safety, clean dpkg/NTP and reboot marker. Expected generated-path absence remains PENDING, not a reason to manually create files. The original P7 SHA evidence is checked across two source checkouts without altering the old files. A local integrity/security failure yields BLOCKED, exit 2. Verified stopped-host safety plus still-unproven external isolation yields HOLD, exit 0.

P8A does **not** query OCI/Cloudflare, alter firewall, fetch CIDRs, start containers, issue certificates, send SMTP, access Box, update DNS, enable timers, restore data or reboot.

## First-start source side-effect inventory

| Action / owner | On first supported start? | Scope and risk | Reversal |
|---|---|---|---|
| `runtime.ensure_paths` | Yes | Creates/updates local runtime, log, data and secret directory metadata; local mutable state | Stop cleans transient secrets; persistent data not automatically rolled back |
| `edge.refresh_origin_policy` | Yes, before Compose up | Fetches Cloudflare IPv4/IPv6 CIDRs; writes local last-known-good policy and Docker DOCKER-USER rules; local network filtering, external HTTP reads | Product-owned refresh or separate supervised firewall intervention; never auto-repair P8A |
| `secrets.load` / admin derivation / `secrets.materialize` | Yes | Reads/decrypts original SOPS, derives PHC, writes root-private ephemeral secrets; may inspect/build pinned container image | Stop cleans ephemeral secrets; protect original SOPS identity |
| `runtime.render` | Yes | Renders Compose, Caddyfile and Dockerfile; includes shared domain, DNS-01 and published 443 | Stop does not change authoritative DNS; generated files may remain |
| `docker compose config` then `up -d --build --wait` | Yes | Pull/build images, create Docker networks/containers, publish TCP/443 and start Vaultwarden/Caddy; externally observable if OCI ingress permits | Product `vwctl stop` removes managed app containers; persistent data and image caches remain |
| Caddy TLS DNS-01 | When Caddy starts and certificate needs issuance | Contacts certificate issuer and Cloudflare DNS API; may create/delete DNS challenge TXT records under shared zone | ACME automation cleans challenges under normal conditions; requires approved test-only authority |
| Cloudflare DNS publication | Via separate `vwctl dns update` or DNS timer, not directly in runtime lifecycle | Changes authoritative proxied A record for configured hostname; high collision risk | Requires separately authorized DNS rollback |
| CrowdSec engine/INPUT bouncer | Already enabled on stopped host | Host INPUT-only nftables filtering; logs/decisions may change while engine runs | Product-owned security operations |
| Cloudflare Worker remediation | Separate invocation; disabled and inactive | May change remote Cloudflare remediation once authorized, with Route Fail Open evidence; shared routes unsafe | Separate explicit disable/recovery procedure |
| SMTP/notifications | A send or failure notification can be triggered by real service operations | External mail or provider delivery; potential real recipients | Cannot unsend mail |
| Backups and automation | Timers remain inactive; later enablement schedules them | Local encrypted recovery; configured Box remote would publish into historical destination; retention zero means no age pruning | Cannot safely overwrite/delete historical backups; use test-only prefix |
| Update/rollback | Separate operator action | May change release pointer, data, config, packages or firewall state | Rollback scope must be independently validated; binary-only rollback is insufficient |

The installed runtime keeps Caddy restart policy `no` and invokes origin firewall refresh before the Docker Compose `up`; this is necessary but not enough to prove origin isolation. Cloudflare-only DOCKER-USER rules cannot replace OCI networking or independently verify a Cloudflare Worker Route.

## P8B design — not authorized

Before even considering a live start, the operator must independently confirm a **distinct test-only hostname** and no Cloudflare Worker Route/wildcard overlap; authoritative DNS/zone and DNS-01 token scope; an intentionally routed, Cloudflare-proxied isolated origin; effective OCI VNIC public IPv4/IPv6, NSGs and security-list ingress; active OCI serial-console access; original offline encrypted kit, private Age identity and separate passphrase custody; and a separated, approved Box destination. Provide verifiable read-only evidence without sharing secrets. A separate disposable clone/VM is preferred if the restored shared-hostname config cannot be isolated without changing its authority.

Once those external prerequisites are accepted, prepare an independent P8B source gate on a new review branch. Its first action must be a fresh source/installed-state and authorized target proof, then explicit operator consent before any local start. Prove the product-owned DOCKER-USER policy is already in force before Caddy 443 is published. Start only via supported `vwctl start`/systemd owner, never a direct Compose up. Keep Cloudflare DNS record change, certificate issuance, Worker invocation, SMTP and Box writes under separate consent where scopes differ. After starting, verify generation, app/Caddy health, firewall, certificate and isolation; use an explicit stop/rollback and check that no shared resources were changed. If any prerequisite fails, HOLD without starting.

## Remaining roadmap

P9: isolated HTTPS, Caddy, authenticated clients, admin Basic Auth, rate limits, security headers and IPv4/IPv6 origin filtering. P10: CrowdSec log acquisition, INPUT versus Docker policy separation, local-only Worker decision source and current invocation-specific Route Fail Open. P11: separately authorized authenticated SMTP/notification delivery. P12: isolated encrypted local and remote backup, independent SHA readback, real recovery rehearsal and zero-prune guarantees. P13: all four natural timers, actual remote-backup observation and separately authorized live reboot. P14: update, failure guard and full app/data/credential/host rollback limitations on a disposable host. P15: release pin, recovery custody, isolation, secure client access, monitoring, RPO/RTO, deployment target and explicit operator GO/NO-GO. Any unresolved critical gate means NO-GO.

Do not treat successful older-release live operation as evidence of rc.12 live operation. Neither a P8A HOLD nor a CI green check authorizes P8B or production.
