#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

network="vwoci-edge-acceptance"
container="vwoci-edge-acceptance-target"
netns="vwoci-edge-client"
host_veth="vwehost0"
client_veth="vweclient0"
server_pid=""
python_image="python:3.12-alpine@sha256:d09d15e60962ca365d1cd544a48773bac9d33f2fb1b00f2aa0deec78ade7dc31"

cleanup() {
  set +e
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" >/dev/null 2>&1 || true
  fi
  ip netns del "${netns}" >/dev/null 2>&1 || true
  ip link del "${host_veth}" >/dev/null 2>&1 || true
  docker rm -f "${container}" >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
}
cleanup
trap cleanup EXIT

docker network create \
  --driver bridge \
  --subnet 172.30.250.0/24 \
  --ipv6 \
  --subnet fd42:5647:4f43:4900::/64 \
  --opt com.docker.network.bridge.name=vwoci0 \
  "${network}" >/dev/null

docker run -d \
  --name "${container}" \
  --network "${network}" \
  -p 443:8080/tcp \
  "${python_image}" \
  python -m http.server 8080 --bind :: >/dev/null

for _ in $(seq 1 30); do
  if curl --noproxy '*' --fail --silent --max-time 1 http://127.0.0.1:443/ >/dev/null; then
    break
  fi
  sleep 1
done
curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:443/ >/dev/null

# Build a real external-client namespace. Cloudflare-range addresses are /32
# and /128 loopback sources routed through the veth peer, so Docker sees them unchanged.
ip netns add "${netns}"
ip link add "${host_veth}" type veth peer name "${client_veth}"
ip link set "${client_veth}" netns "${netns}"
ip addr add 192.0.2.1/30 dev "${host_veth}"
ip -6 addr add 2001:db8:ffff::1/64 dev "${host_veth}"
ip link set "${host_veth}" up

ip netns exec "${netns}" ip link set lo up
ip netns exec "${netns}" ip addr add 192.0.2.2/30 dev "${client_veth}"
ip netns exec "${netns}" ip -6 addr add 2001:db8:ffff::2/64 dev "${client_veth}"
ip netns exec "${netns}" ip link set "${client_veth}" up
ip netns exec "${netns}" ip addr add 173.245.48.10/32 dev lo
ip netns exec "${netns}" ip addr add 198.51.100.10/32 dev lo
ip netns exec "${netns}" ip -6 addr add 2400:cb00::10/128 dev lo
ip netns exec "${netns}" ip -6 addr add 2001:4860::10/128 dev lo
ip netns exec "${netns}" ip route add default via 192.0.2.1
ip netns exec "${netns}" ip -6 route add default via 2001:db8:ffff::1

ip route add 173.245.48.10/32 via 192.0.2.2 dev "${host_veth}"
ip route add 198.51.100.10/32 via 192.0.2.2 dev "${host_veth}"
ip -6 route add 2400:cb00::10/128 via 2001:db8:ffff::2 dev "${host_veth}"
ip -6 route add 2001:4860::10/128 via 2001:db8:ffff::2 dev "${host_veth}"
sysctl -q -w net.ipv6.conf.all.forwarding=1

PYTHONPATH=. python3 - <<'PY'
from vaultwarden_oci import edge

policy = edge.validate_policy(
    "173.245.48.0/20\n103.21.244.0/22",
    "2400:cb00::/32",
    fetched_at=1,
    source="acceptance",
)
edge.apply_origin_policy(policy)
PY

# Allowed IPv4 must complete both request and reply directions.
ip netns exec "${netns}" \
  curl --noproxy '*' --interface 173.245.48.10 --fail --silent --max-time 5 \
  http://192.0.2.1:443/ >/dev/null

# A non-Cloudflare IPv4 source must not reach the published port.
if ip netns exec "${netns}" \
  curl --noproxy '*' --interface 198.51.100.10 --fail --silent --max-time 2 \
  http://192.0.2.1:443/ >/dev/null 2>&1; then
  echo "non-Cloudflare IPv4 unexpectedly reached published 443" >&2
  exit 1
fi

# Allowed IPv6 traverses the native IPv6 bridge/ip6tables forwarding path.
ip netns exec "${netns}" \
  curl --noproxy '*' --interface 2400:cb00::10 --fail --silent --max-time 5 \
  'http://[2001:db8:ffff::1]:443/' >/dev/null

# A non-Cloudflare IPv6 source must not reach the published port.
if ip netns exec "${netns}" \
  curl --noproxy '*' --interface 2001:4860::10 --fail --silent --max-time 2 \
  'http://[2001:db8:ffff::1]:443/' >/dev/null 2>&1; then
  echo "non-Cloudflare IPv6 unexpectedly reached published 443" >&2
  exit 1
fi

# Container-originated traffic whose original destination port is 443 must
# remain usable because the origin policy is scoped to packets going *toward*
# vwoci0, not traffic leaving that bridge.
ip netns exec "${netns}" python3 -m http.server 443 --bind 192.0.2.2 >/tmp/vwoci-edge-http.log 2>&1 &
server_pid=$!
for _ in $(seq 1 20); do
  if docker exec "${container}" python -c \
    "import urllib.request; assert urllib.request.urlopen('http://192.0.2.2:443/', timeout=1).status == 200" \
    >/dev/null 2>&1; then
    exit 0
  fi
  sleep 0.25
done

echo "container-originated :443 egress was not usable" >&2
exit 1
