"""VaultWarden-OCI V2 Python package."""

# The scheduler units are part of immutable install ownership.  Registration is
# retained here for compatibility with the existing installer constant until
# that constant becomes release-manifest data; update activation and unit
# migration themselves are now explicit call-graph dependencies rather than
# package-import monkeypatches.
from . import update_schedule as _update_schedule

_update_schedule.register()

del _update_schedule
