"""VaultWarden-OCI V2 Python package."""

from . import update_schedule as _update_schedule

_update_schedule.register()

# The immutable updater remains the owner for unit replacement. Extend only
# that bounded primitive so a release may introduce/remove newly owned units
# transactionally without changing legacy updater activation identity.
from . import update as _update
from . import update_unit_migration as _update_unit_migration

_update._install_units = _update_unit_migration.install_units
_update._restore_units = _update_unit_migration.restore_units

del _update_schedule, _update, _update_unit_migration
