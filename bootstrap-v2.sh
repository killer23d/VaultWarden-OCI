#!/bin/bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "FAIL: bootstrap must run as root" >&2
  exit 1
fi

script_path=$(/usr/bin/readlink -f -- "${BASH_SOURCE[0]}")
repo_root=$(cd -- "$(/usr/bin/dirname -- "$script_path")" && pwd)

printf 'INFO: bootstrap-v2.sh is a compatibility shim; setup.sh is the supported first-run surface.\n' >&2
exec "$repo_root/setup.sh" "$@"
