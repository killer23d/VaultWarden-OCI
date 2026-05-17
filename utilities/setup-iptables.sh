#!/usr/bin/env bash
# setup-iptables.sh - idempotent NAT rules for VaultWarden OCI Docker networks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  COMPOSE_FILE="docker-compose.yml.example"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found" >&2
  exit 1
fi

if ! command -v iptables >/dev/null 2>&1; then
  echo "ERROR: iptables command not found" >&2
  exit 1
fi

# Verify python3 is available before using it for subnet discovery.
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 command not found — required for subnet discovery from compose config" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -n "$0" "$@"
  fi
  echo "ERROR: run as root (or install/configure sudo)" >&2
  exit 1
fi

# Warn if nftables is active alongside iptables. Running both
# can cause conflicting firewall policies where nft rules override iptables.
if command -v nft >/dev/null 2>&1; then
  if nft list ruleset 2>/dev/null | grep -q .; then
    echo "WARN: nftables ruleset is active on this host." >&2
    echo "WARN: Running iptables alongside nftables may cause conflicting firewall policies." >&2
    echo "WARN: Verify that nftables is not shadowing these iptables rules." >&2
    echo "WARN: Consider using only one firewall framework." >&2
  fi
fi

# Verify an SSH ACCEPT rule exists in the INPUT chain before making
# any changes. Adding MASQUERADE or FORWARD rules while accidentally blocking
# SSH could lock out the operator from the host.
_ssh_port="${SSH_PORT:-22}"
_ssh_ok=false
if iptables -L INPUT -n 2>/dev/null | grep -qE "ACCEPT.*(tcp dpt:${_ssh_port}|state.*ESTABLISHED|multiport.*${_ssh_port})"; then
  _ssh_ok=true
elif iptables -L INPUT -n 2>/dev/null | grep -q "ACCEPT.*all.*0\.0\.0\.0"; then
  # Default open INPUT (typical in OCI before REJECT rule) — SSH is accessible.
  _ssh_ok=true
fi
if [[ "$_ssh_ok" != "true" ]]; then
  echo "WARN: Could not confirm an SSH ACCEPT rule in the INPUT chain." >&2
  echo "WARN: Proceeding, but verify SSH port ${_ssh_port} remains accessible after this script." >&2
fi

# Save current iptables rules before any modifications.
# On ERR, INT, or TERM, automatically restore the saved rules so the host
# is not left with a partial/broken iptables configuration.
_ipt_backup_v4=""
_ipt_backup_v6=""
_ipt_cleanup() {
  local _rc=$?
  if [[ -n "$_ipt_backup_v4" && -f "$_ipt_backup_v4" ]]; then
    echo "ROLLBACK: Restoring iptables rules from: $_ipt_backup_v4" >&2
    iptables-restore < "$_ipt_backup_v4" 2>/dev/null || true
    rm -f "$_ipt_backup_v4"
  fi
  if [[ -n "$_ipt_backup_v6" && -f "$_ipt_backup_v6" ]]; then
    echo "ROLLBACK: Restoring ip6tables rules from: $_ipt_backup_v6" >&2
    ip6tables-restore < "$_ipt_backup_v6" 2>/dev/null || true
    rm -f "$_ipt_backup_v6"
  fi
  return $_rc
}
_ipt_backup_v4="$(mktemp -p "${PROJECT_ROOT}" .iptables-backup.XXXXXX)"
iptables-save > "$_ipt_backup_v4" 2>/dev/null || {
  echo "WARN: Could not save current iptables state — rollback on failure will not be available." >&2
  rm -f "$_ipt_backup_v4"; _ipt_backup_v4=""
}
if command -v ip6tables-save >/dev/null 2>&1; then
  _ipt_backup_v6="$(mktemp -p "${PROJECT_ROOT}" .ip6tables-backup.XXXXXX)"
  ip6tables-save > "$_ipt_backup_v6" 2>/dev/null || {
    rm -f "$_ipt_backup_v6"; _ipt_backup_v6=""
  }
fi
trap '_ipt_cleanup' ERR INT TERM
# On success: clean up backup files without rollback.
trap 'rm -f "${_ipt_backup_v4:-}" "${_ipt_backup_v6:-}"' EXIT

NETWORK_NAMES=()
set +e
mapfile -t NETWORK_NAMES < <(
  docker compose -f "$COMPOSE_FILE" config --services >/dev/null 2>&1 &&
  docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null |
  python3 -c '
import json, sys
c = json.load(sys.stdin)
nets = c.get("networks", {})
for name, cfg in nets.items():
    if cfg.get("driver", "bridge") != "bridge":
        continue
    if cfg.get("internal", False) is True:
        continue
    if cfg.get("external", False) is True:
        continue
    print(name)
' 2>/dev/null
)
set -e

# Fallback when JSON config discovery is unavailable or returns nothing.
if [[ ${#NETWORK_NAMES[@]} -eq 0 ]]; then
  NETWORK_NAMES=(vaultwarden_egress caddy_external)
fi

declare -a SUBNETS=()
for net in "${NETWORK_NAMES[@]}"; do
  # Resolve subnet directly from the JSON config — avoids fragile YAML awk parsing.
  subnet=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | \
    python3 -c "
import json, sys
c = json.load(sys.stdin)
nets = c.get('networks', {})
n = nets.get('$net', {})
cfgs = n.get('ipam', {}).get('config', [])
print(cfgs[0]['subnet'] if cfgs else '')
" 2>/dev/null || true)

  # Fallback: inspect the running network by constructed name when no static subnet is pinned.
  if [[ -z "${subnet:-}" ]]; then
    full_name=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | \
      python3 -c "
import json, sys
c = json.load(sys.stdin)
nets = c.get('networks', {})
n = nets.get('$net', {})
print(n.get('name', '${net}_network'))
" 2>/dev/null || true)
    [[ -n "${full_name:-}" ]] || full_name="${net}_network"
    subnet=$(docker network inspect -f '{{with index .IPAM.Config 0}}{{.Subnet}}{{end}}' \
      "$full_name" 2>/dev/null || true)
  fi

  if [[ -n "${subnet:-}" ]]; then
    SUBNETS+=("$subnet")
  fi
done

# Always include pinned egress subnet as a deterministic baseline.
SUBNETS+=("172.21.0.0/16")

# Deduplicate
mapfile -t UNIQUE_SUBNETS < <(printf '%s\n' "${SUBNETS[@]}" | awk 'NF && !seen[$0]++')

for subnet in "${UNIQUE_SUBNETS[@]}"; do
  if iptables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
    echo "OK: MASQUERADE already present for $subnet (IPv4)"
    continue
  fi

  iptables -t nat -A POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE
  echo "ADDED: MASQUERADE for $subnet (IPv4)"
done

# Add ip6tables MASQUERADE rules mirroring the IPv4 rules above.
# Docker assigns IPv6 ULA subnets (fd00::/8) when IPv6 is enabled in daemon.json.
# Without ip6tables MASQUERADE, IPv6 container traffic cannot reach the internet.
# Note: This is a best-effort mirror — if ip6tables is absent (some kernels
# compile without ip6tables support), we emit a clear WARNING and continue.
if command -v ip6tables >/dev/null 2>&1; then
  for subnet in "${UNIQUE_SUBNETS[@]}"; do
    # Skip IPv4-only CIDR notation — ip6tables only handles IPv6 prefixes.
    if [[ "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ ]]; then
      continue
    fi
    if ip6tables -t nat -C POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE >/dev/null 2>&1; then
      echo "OK: MASQUERADE already present for $subnet (IPv6)"
      continue
    fi
    ip6tables -t nat -A POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE
    echo "ADDED: MASQUERADE for $subnet (IPv6)"
  done
else
  echo "WARN: ip6tables not found — IPv6 MASQUERADE rules not applied." >&2
  echo "WARN: Container IPv6 traffic may not reach the internet." >&2
fi

# Remove OCI's default FORWARD REJECT rule if present (safe to run repeatedly).
# On a fresh Oracle Cloud instance, OCI injects:
#   -A FORWARD -j REJECT --reject-with icmp-host-prohibited
# into the FORWARD chain. This blocks all container-to-container and
# container-to-internet forwarding until removed, making a fresh deploy fail
# silently. The while loop handles the case where the rule appears more than once.
count=0
while iptables -D FORWARD -j REJECT --reject-with icmp-host-prohibited 2>/dev/null; do
  count=$((count + 1))
done
if [[ $count -gt 0 ]]; then
  echo "REMOVED: OCI default FORWARD REJECT rule (x${count})"
else
  echo "OK: OCI FORWARD REJECT rule not present (nothing to remove)"
fi

# Accept only the three pinned VaultWarden compose subnets in DOCKER-USER.
# Using pinned subnets (not all RFC1918) prevents any future Docker project
# on this host from inheriting unrestricted forwarding between all networks.
# Subnets: 172.21.0.0/16 (vaultwarden_egress), 172.22.0.0/16 (caddy_external),
#          172.23.0.0/16 (postfix_relay) — pinned in docker-compose.yml.example.
# Keep this idempotent and append-only so repeated runs remain predictable.
if iptables -t filter -S DOCKER-USER >/dev/null 2>&1; then
  for cidr in "172.21.0.0/16" "172.22.0.0/16" "172.23.0.0/16"; do
    if ! iptables -t filter -C DOCKER-USER -s "$cidr" -j ACCEPT >/dev/null 2>&1; then
      iptables -t filter -A DOCKER-USER -s "$cidr" -j ACCEPT
      echo "ADDED: DOCKER-USER ACCEPT for pinned VaultWarden subnet $cidr"
    else
      echo "OK: DOCKER-USER ACCEPT already present for pinned subnet $cidr"
    fi
  done
else
  echo "WARN: DOCKER-USER chain not available; skipping forward-policy remediation"
fi

# Fail loudly if netfilter-persistent is absent, rather than
# silently continuing. Without persistence the rules are lost on reboot.
if command -v netfilter-persistent >/dev/null 2>&1; then
  if ! netfilter-persistent save >/dev/null 2>&1; then
    echo "ERROR: netfilter-persistent save failed — rules may not survive reboot." >&2
    exit 1
  fi
  echo "INFO: persisted iptables rules with netfilter-persistent"
else
  echo "WARN: netfilter-persistent not installed — rules will be lost on reboot." >&2
  echo "WARN: Install with: apt-get install -y netfilter-persistent iptables-persistent" >&2
fi
