#!/usr/bin/env bash
# setup-iptables.sh - idempotent NAT rules for VaultWarden OCI Docker networks
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
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

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -n "$0" "$@"
  fi
  echo "ERROR: run as root (or install/configure sudo)" >&2
  exit 1
fi

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
    echo "OK: MASQUERADE already present for $subnet"
    continue
  fi

  iptables -t nat -A POSTROUTING -s "$subnet" ! -o docker0 -j MASQUERADE
  echo "ADDED: MASQUERADE for $subnet"
done

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

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
  echo "INFO: persisted iptables rules with netfilter-persistent"
fi
