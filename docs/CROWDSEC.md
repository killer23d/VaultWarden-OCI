# CrowdSec + Cloudflare Workers Bouncer

This document covers everything needed to install, configure, and operate
CrowdSec with the dual-bouncer setup in VaultWarden-OCI:

- **`crowdsec-firewall-bouncer`** — enforces ALL decisions (including community
  lists) at the OS/iptables level. No Cloudflare quota involved.
- **`crowdsec-cloudflare-worker-bouncer`** — pushes locally-generated decisions
  to Cloudflare Workers KV for edge-level blocking.

> **CF bouncer docs:** <https://docs.crowdsec.net/u/bouncers/cloudflare-workers>  
> **CF bouncer repo:** <https://github.com/crowdsecurity/cs-cloudflare-worker-bouncer>

---

## Architecture

```
VaultWarden / Caddy / SSH logs
        │
        ▼
  CrowdSec engine          ← detects attacks from log streams
        │  (LAPI port 8080)
        ├─────────────────────────────────────────────────────┐
        ▼                                                     ▼
  crowdsec-firewall-bouncer          crowdsec-cloudflare-worker-bouncer
  (iptables / nftables)              (Cloudflare API)
  blocks ALL decisions               blocks locally-generated decisions
  including community lists          at the CF edge (free-plan guard)
                                             │
                                             ▼
                                     Cloudflare Workers KV
                                             │
                                             ▼
                                     Cloudflare Worker script
                                     (runs on every inbound request)
                                             │
                                             ▼
                                     block / challenge matched IPs
                                     pass-through for clean traffic
```

Decision flow: CrowdSec detects a threat → writes a decision to its local
database → firewall bouncer blocks at OS level immediately → CF bouncer
pushes the decision to Workers KV → the Worker script checks KV on every
request and blocks/challenges the IP at the Cloudflare edge.

---

## Part 1 — Cloudflare Dashboard Setup

Do this **before** running the setup script. You need two things from
Cloudflare: an API token and two IDs.

### 1.1 Gather your IDs

| Value | Where to find it |
|---|---|
| **Zone ID** | Cloudflare dashboard → your domain → Overview → right sidebar → Zone ID |
| **Account ID** | Cloudflare dashboard → any domain → Overview → right sidebar → Account ID |

Copy both into `.env`:

```dotenv
CLOUDFLARE_ZONE_ID=abc123...   # 32-char hex
CF_ACCOUNT_ID=def456...        # 32-char hex
```

### 1.2 Create the Workers bouncer API token

1. Go to **Cloudflare dashboard → My Profile → API Tokens**  
   _(Use **My Profile**, not the Account-level API Tokens page — user tokens
   carry the User Details permission needed by the bouncer.)_
2. Click **Create Token** → **Create Custom Token**.
3. Name it something like `crowdsec-worker-bouncer`.
4. Add **exactly** the following permissions:

| Resource | Permission |
|---|---|
| Account → Workers KV Storage | Edit |
| Account → Workers Scripts | Edit |
| Account → Account Settings | Read |
| Account → Turnstile | Edit |
| Account → D1 | Edit |
| User → User Details | Read |
| Zone → DNS | Read |
| Zone → Workers Routes | Edit |
| Zone → Zone | Read |

5. Under **Zone Resources**, select **Specific zone** → your domain.
6. Under **Account Resources**, select **All accounts** (or your specific account).
7. Click **Continue to summary** → **Create Token**.
8. **Copy the token now** — it is shown only once.

Store the token in the project secrets store (never in `.env` directly):

```bash
sudo utilities/setup-secrets.sh rotate cf_worker_bouncer_token
# Paste the token when prompted.
```

The setup script reads it from:
```
${PROJECT_STATE_DIR}/secrets/.docker_secrets/cf_worker_bouncer_token
```

### 1.3 Set Worker route to Fail Open (post-install)

After the setup script has deployed the Worker, you **must** set the route
fail mode to **Fail Open** to prevent false lockouts:

1. Cloudflare dashboard → your domain → **Workers Routes**.
2. Find the route created by the bouncer (e.g. `yourdomain.com/*`).
3. Click **Edit** → set **Request limit failure mode** to **Fail open**.
4. Save.

This ensures that if the bouncer daemon or KV store is temporarily unavailable,
legitimate traffic (including your own password manager sync) passes through
rather than being blocked.

---

## Part 2 — New VM Quick-Start

Complete Cloudflare dashboard setup (Part 1) first, then:

### Step 1 — Populate `.env`

```bash
cp .env.example .env
# Set at minimum:
#   DOMAIN, ADMIN_EMAIL
#   CLOUDFLARE_ZONE_ID, CF_ACCOUNT_ID
#   CLOUDFLARE_PROXY_ENABLED=true
#   CF_FREE_PLAN=true          (keep true on free Cloudflare plan)
#   CF_AUTONOMOUS_MODE=false   (keep false for daemon mode)
```

### Step 2 — Store the Workers bouncer token

```bash
sudo utilities/setup-secrets.sh rotate cf_worker_bouncer_token
# Paste the token you created in section 1.2.
```

### Step 3 — Run the setup script

```bash
# Interactive (recommended for first run — prompts for any missing values):
sudo ./utilities/setup-crowdsec.sh

# Fully automated (CI / re-provisioning — token must be in secrets store):
sudo ./utilities/setup-crowdsec.sh --auto

# To pin specific versions (recommended for reproducible deploys):
# Set CROWDSEC_VERSION and CF_WORKER_BOUNCER_VERSION in .env first, then:
sudo ./utilities/setup-crowdsec.sh
```

The script runs 9 phases:

| Phase | What it does |
|---|---|
| 1 | Installs CrowdSec from the packagecloud repo |
| 2 | Installs `crowdsec-cloudflare-worker-bouncer` (apt → tarball → Go source) |
| 3 | Installs hub collections (linux, caddy, http-cve, vaultwarden) |
| 4 | Writes the acquisition config (tells CrowdSec which log files to watch) |
| 5 | Generates and registers the CrowdSec LAPI key for the bouncer |
| 6 | Renders and writes the bouncer config, starts service |
| 7 | Applies custom `profiles.yaml` (if present) |
| 8 | Enables and starts all services (firewall bouncer + CF bouncer) |
| 9 | Writes your admin IP to the CrowdSec allowlist |

### Step 4 — Set Worker route to Fail Open

Complete step 1.3 in the Cloudflare dashboard now.

### Step 5 — Verify

```bash
# CrowdSec engine running?
sudo systemctl status crowdsec

# Both bouncers running?
sudo systemctl status crowdsec-firewall-bouncer
sudo systemctl status crowdsec-cloudflare-worker-bouncer

# Both bouncers registered with LAPI?
sudo cscli bouncers list

# Collections installed?
sudo cscli collections list

# Host-level blocks active (firewall bouncer)?
sudo iptables -L CROWDSEC_CHAIN -n | head
sudo iptables -L DOCKER-USER -n | head

# Any decisions already taken?
sudo cscli decisions list

# Community list decisions active?
sudo cscli decisions list --origin lists

# Metrics (shows events processed per parser/scenario):
sudo cscli metrics
```

---

## Part 3 — Deployment Modes

### Daemon mode (default, `CF_AUTONOMOUS_MODE=false`)

- The Go binary runs as a persistent systemd service
  (`crowdsec-cloudflare-worker-bouncer.service`).
- It watches the CrowdSec LAPI and pushes new decisions to Workers KV in
  near-real-time (every `update_frequency` seconds, default 10 s).
- The Worker script deployed to Cloudflare checks KV on every inbound request.
- **Recommended** for VaultWarden — decisions propagate in ~10 seconds.

### Autonomous mode (`CF_AUTONOMOUS_MODE=true`)

```bash
sudo ./utilities/setup-crowdsec.sh --autonomous
```

- The binary runs once, deploys the Worker + KV namespace to Cloudflare, then exits.
- A Cloudflare **Scheduled Worker** (cron trigger) pulls decisions from your
  CrowdSec LAPI every 5 minutes.
- No persistent daemon needed.
- **Requirement:** your CrowdSec LAPI (`http://YOUR_SERVER_IP:8080`) must be
  reachable from the public internet for the scheduled Worker to pull decisions.
  Open port 8080 in your OCI Security List (restrict to Cloudflare source IPs
  if possible).
- Best suited for low-traffic deployments where 5-minute decision lag is acceptable.

---

## Part 4 — Cloudflare Free Plan Limits

| Limit | Free plan | Impact |
|---|---|---|
| KV writes | 1,000 / day | Initial sync is truncated; incremental updates stay within budget |
| KV reads | 100,000 / day | One read per Worker invocation; Vaultwarden traffic is far below this |
| Worker requests | 100,000 / day | One invocation per inbound HTTP request; not a binding constraint |
| Worker scripts | 100 total | One script per bouncer; not a concern |
| KV namespaces | 100 total | One namespace per bouncer; not a concern |

### Free-plan KV write guard

The `CF_FREE_PLAN=true` default in `.env` restricts the CF bouncer to syncing only
decisions generated **locally** by your CrowdSec engine and `cscli` via the
`only_include_decisions_from: ["cscli", "crowdsec"]` setting in the bouncer
config. CrowdSec community blocklists can contain 10K–100K IPs and would
exhaust the 1,000-write daily budget on the very first sync. Locally-generated
decisions for a self-hosted Vaultwarden instance are typically in the range of
0–50 per day, well within budget.

The **firewall bouncer** enforces community list decisions at the OS level
regardless of this setting — no KV quota is involved.

To disable the CF bouncer guard (paid plan only):
```dotenv
# .env
CF_FREE_PLAN=false
```
Then re-run: `sudo ./utilities/setup-crowdsec.sh --force`

---

## Part 5 — Day-2 Operations

### Bouncer service management

```bash
# Status
sudo systemctl status crowdsec-cloudflare-worker-bouncer
sudo systemctl status crowdsec-firewall-bouncer

# Restart after config change
sudo systemctl restart crowdsec-cloudflare-worker-bouncer

# View logs (last 50 lines, follow)
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 50 -f

# Stop
sudo systemctl stop crowdsec-cloudflare-worker-bouncer
```

### Managing decisions

```bash
# List active bans
sudo cscli decisions list

# Manually ban an IP for 24 h
sudo cscli decisions add --ip 198.51.100.42 --duration 24h

# Unban an IP
sudo cscli decisions delete --ip 198.51.100.42

# Recent alerts (last 24 h)
sudo cscli alerts list --since 24h
```

### Allowlisting your admin IP

Add your own IP to prevent accidental self-bans:

```bash
# Allowlist a single IP
sudo cscli decisions add --ip "$(curl -s https://ifconfig.me)" --type allow --duration 8760h

# Or re-run the setup script with --admin-ip to write a persistent parser allowlist:
sudo ./utilities/setup-crowdsec.sh --admin-ip 203.0.113.42

# For a CIDR range:
sudo ./utilities/setup-crowdsec.sh --admin-ip 203.0.113.0/24
```

The `--admin-ip` flag writes a permanent YAML allowlist to:
```
/etc/crowdsec/parsers/s02-enrich/vaultwarden-admin-allowlist.yaml
```
This survives hub updates and CrowdSec reinstalls.

### If you are locked out

```bash
# 1. SSH to the server (CrowdSec bans do not affect SSH)
# 2. Delete the ban
sudo cscli decisions delete --ip <your-ip>
# 3. Add a persistent allowlist entry
sudo ./utilities/setup-crowdsec.sh --admin-ip <your-ip>
```

### Rotating the Cloudflare API token

```bash
# 1. Create a new token in Cloudflare dashboard (same permissions as section 1.2)
# 2. Store it in secrets
sudo utilities/setup-secrets.sh rotate cf_worker_bouncer_token
# 3. Re-run setup to apply
sudo ./utilities/setup-crowdsec.sh --force
```

### Checking CrowdSec hub updates

```bash
sudo cscli hub update
sudo cscli hub upgrade
sudo systemctl restart crowdsec
```

---

## Part 6 — Config File Reference

### Bouncer config

| File | Purpose |
|---|---|
| `crowdsec/crowdsec-cloudflare-worker-bouncer.yaml.example` | Template rendered by `setup-crowdsec.sh` |
| `/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml` | Live config (mode 600, root-only) |

### Key config fields

| Field | Default | Notes |
|---|---|---|
| `crowdsec_config.lapi_url` | `http://127.0.0.1:8080/` | Correct for host-only CrowdSec install |
| `crowdsec_config.only_include_decisions_from` | `["cscli", "crowdsec"]` | Free-plan guard; empty list = all sources |
| `crowdsec_config.update_frequency` | `10` | Seconds between LAPI polls |
| `cloudflare_config.accounts[].zones[].actions` | `["ban"]` | `captcha` also supported if Turnstile is configured |
| `cloudflare_config.accounts[].zones[].routes_to_protect` | `["yourdomain.com/*"]` | Must be explicit — see note below |
| `log_level` | `info` | `debug` for troubleshooting |

> **`routes_to_protect` must not be empty.** Since bouncer v0.9.0,
> `routes_to_protect: []` is interpreted literally as "bind to no routes"
> rather than "bind to all routes in the zone". The Worker will deploy
> successfully but no route will be created, so requests will not be
> inspected. `setup-crowdsec.sh` always substitutes an explicit
> `DOMAIN_NAME/*` route at render time.

### `.env` variables

| Variable | Default | Purpose |
|---|---|---|
| `CLOUDFLARE_PROXY_ENABLED` | `true` | Master switch; bouncer skips all phases if `false` |
| `CLOUDFLARE_ZONE_ID` | _(required)_ | Your Cloudflare zone ID |
| `CF_ACCOUNT_ID` | _(required)_ | Your Cloudflare account ID |
| `CF_FREE_PLAN` | `true` | Enables `only_include_decisions_from` KV write guard |
| `CF_AUTONOMOUS_MODE` | `false` | `true` = autonomous mode (no persistent daemon) |
| `CROWDSEC_VERSION` | _(blank = latest)_ | Pin CrowdSec engine version |
| `CF_WORKER_BOUNCER_VERSION` | _(blank = latest)_ | Pin CF bouncer version |
| `FIREWALL_BOUNCER_VERSION` | _(blank = latest)_ | Pin firewall bouncer version |

---

## Part 7 — Troubleshooting

### Bouncer fails with YAML parse error

Symptom in `journalctl`:
```
level=fatal msg="unable to read config file: [...]: [103:13] value is not allowed in this context"
```

This means the rendered config has malformed YAML — most likely the
`routes_to_protect` block has both `[]` and a list item on the same key:

```yaml
# BAD — parser rejects this
routes_to_protect: []
  - "bw.example.com/*"

# GOOD
routes_to_protect:
  - "bw.example.com/*"
```

Fix: re-render from the fixed template:
```bash
sudo ./utilities/setup-crowdsec.sh --force
```

### "failed to send metrics: 200 OK" warning

The bouncer emits this warning every 15 minutes:
```
level=warning msg="failed to send metrics: 200 OK"
```
This is a **known cosmetic bug** in the upstream bouncer — the metrics sender
misclassifies HTTP 200 (success) as a failure. IP blocking is not affected.
The warning can be safely ignored.

### Bouncer fails to start (other causes)

```bash
sudo journalctl -u crowdsec-cloudflare-worker-bouncer -n 100 --no-pager
```

Common causes:
- **`lapi_key` rejected** — the key in the bouncer config doesn't match the one
  registered in CrowdSec. Re-run: `sudo ./utilities/setup-crowdsec.sh --force`
- **`api_token` error** — the Cloudflare token has wrong permissions or was
  revoked. Rotate: `sudo utilities/setup-secrets.sh rotate cf_worker_bouncer_token`
- **`account_id` not found** — ensure `CF_ACCOUNT_ID` in `.env` matches your
  Cloudflare account exactly (32-char hex, no spaces).

### KV writes exhausted (free plan)

Symptom: bouncer log shows `kv write quota exceeded` or similar.

```bash
# Confirm CF_FREE_PLAN=true is set
grep CF_FREE_PLAN .env

# Check what's in only_include_decisions_from
sudo grep only_include /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml

# If community lists are slipping through, force-rewrite the config
sudo ./utilities/setup-crowdsec.sh --force
```

### Worker not enforcing decisions

1. Check the Worker is deployed: Cloudflare dashboard → your domain → Workers.
2. Check the Worker route covers your domain: Workers Routes → confirm `yourdomain.com/*` exists.
3. Confirm fail mode is **Fail Open**: Workers Routes → Edit → Request limit failure mode.
4. Check KV namespace exists and has entries:
   Cloudflare dashboard → Workers → KV → `CROWDSECCFBOUNCERNS`.
5. Test manually:
   ```bash
   # Add a test ban for a harmless IP
   sudo cscli decisions add --ip 203.0.113.1 --duration 1m
   # Wait 15 s, then check KV has the entry
   sudo cscli decisions list
   # Remove after testing
   sudo cscli decisions delete --ip 203.0.113.1
   ```

### CrowdSec not detecting attacks

```bash
# Check which log files are being watched
sudo cscli metrics | grep acquisition

# Check the acquisition config
cat /etc/crowdsec/acquis.d/vaultwarden.yaml

# Check active parsers
sudo cscli parsers list

# Check active scenarios
sudo cscli scenarios list
```

### Checking bouncer registration

```bash
sudo cscli bouncers list
# Should show both:
#   cloudflare-worker-bouncer   ✔
#   crowdsecurity/firewall-bouncer  ✔
```

---

## Part 8 — Migration from Legacy Bouncer

If you previously had `crowdsec-cloudflare-worker-bouncer` installed:

```bash
# 1. Stop and disable the old service
sudo systemctl stop crowdsec-cloudflare-worker-bouncer || true
sudo systemctl disable crowdsec-cloudflare-worker-bouncer || true

# 2. Deregister the old bouncer
sudo cscli bouncers delete cloudflare-bouncer || true

# 3. Run the new setup (handles everything else)
sudo ./utilities/setup-crowdsec.sh --force

# 4. Set Worker route to Fail Open in Cloudflare dashboard (section 1.3)
```

The old binary at `/usr/local/bin/crowdsec-cloudflare-worker-bouncer` and the old
config at `/etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml` can be
removed after confirming the new bouncer is healthy:

```bash
sudo rm -f /usr/local/bin/crowdsec-cloudflare-worker-bouncer
sudo rm -f /etc/crowdsec/bouncers/crowdsec-cloudflare-worker-bouncer.yaml
sudo rm -f /etc/systemd/system/crowdsec-cloudflare-worker-bouncer.service
sudo systemctl daemon-reload
```
