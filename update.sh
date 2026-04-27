#!/usr/bin/env bash
# DEPRECATED: Use './maintenance.sh update' instead.
echo "DEPRECATED: update.sh is deprecated. Use './maintenance.sh update' instead." >&2
exec "$(dirname "${BASH_SOURCE[0]}")/maintenance.sh" update "$@"
