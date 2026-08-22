#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "FAIL: bootstrap must run as root" >&2
  exit 1
fi

script_path=$(/usr/bin/readlink -f -- "${BASH_SOURCE[0]}")
repo_root=$(cd -- "$(/usr/bin/dirname -- "$script_path")" && pwd)

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

case "$(/usr/bin/uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *)
    echo "FAIL: supported architectures are amd64 and arm64" >&2
    exit 1
    ;;
esac

cd -- "$repo_root"
unset PYTHONPATH
exec /usr/bin/python3 -B -E -m vaultwarden_oci.install --source "$repo_root" "$@"
