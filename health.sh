#!/usr/bin/env bash
# DEPRECATED: Use './maintenance.sh health' instead.
echo "DEPRECATED: health.sh is deprecated. Use './maintenance.sh health' instead." >&2
exec "$(dirname "${BASH_SOURCE[0]}")/maintenance.sh" health "$@"
