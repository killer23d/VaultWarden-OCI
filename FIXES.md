# CrowdSec setup fixes

- Canonical Cloudflare firewall token file path: `${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets/crowdsec_cf_firewall_token`.
- `utilities/setup-crowdsec.sh` now writes the token there after prompt and reuses it on reruns to avoid prompts.
- `crowdsec-cloudflare-bouncer` arm64 fallback: script attempts `go install github.com/crowdsecurity/cs-cloudflare-bouncer/cmd/crowdsec-cloudflare-bouncer@latest` when no linux_arm64 release asset exists.
- If binary exists but systemd unit does not, script creates `/etc/systemd/system/crowdsec-cloudflare-bouncer.service` and reloads daemon.

## Verify

1. `sudo ./utilities/setup-crowdsec.sh` (second run should show no token prompt).
2. `sudo systemctl status crowdsec-cloudflare-bouncer --no-pager` (active/running).
3. `sudo cscli bouncers list | grep -E "cloudflare-bouncer|crowdsecurity/cloudflare-bouncer"` (registered bouncer present).
4. `sudo test -s ${PROJECT_STATE_DIR:-/var/lib/vaultwarden}/secrets/.docker_secrets/crowdsec_cf_firewall_token && echo OK`
