#!/usr/bin/env bash
# DEPRECATED: Use './setup.sh --phase=secrets' instead.
echo "DEPRECATED: setup-secrets.sh is deprecated. Use './setup.sh --phase=secrets' instead." >&2
exec "$(dirname "${BASH_SOURCE[0]}")/setup.sh" --phase=secrets "$@"
