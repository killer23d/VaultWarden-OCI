#!/usr/bin/env bash
# DEPRECATED: Use './setup.sh --phase=systemd' instead.
echo "DEPRECATED: setup-systemd.sh is deprecated. Use './setup.sh --phase=systemd' instead." >&2
exec "$(dirname "${BASH_SOURCE[0]}")/setup.sh" --phase=systemd "$@"
