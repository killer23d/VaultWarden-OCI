#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  printf 'FAIL: setup must run as root; use sudo ./setup.sh install ...\n' >&2
  exit 1
fi

script_path=$(/usr/bin/readlink -f -- "${BASH_SOURCE[0]}")
repo_root=$(cd -- "$(/usr/bin/dirname -- "$script_path")" && pwd)
cd -- "$repo_root"
unset PYTHONPATH
exec /usr/bin/python3 -B -E -m vaultwarden_oci.setup_frontend "$@"
