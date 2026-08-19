#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "FAIL: bootstrap must run as root" >&2
  exit 1
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ ! -r /etc/os-release ]]; then
  echo "FAIL: cannot read /etc/os-release" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ ${ID:-} != "ubuntu" || ${VERSION_ID:-} != "24.04" ]]; then
  echo "FAIL: Ubuntu 24.04 is required" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *)
    echo "FAIL: supported architectures are amd64 and arm64" >&2
    exit 1
    ;;
esac

exec python3 -m vaultwarden_oci.install --source "$repo_root"
