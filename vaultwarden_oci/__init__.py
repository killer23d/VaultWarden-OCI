"""VaultWarden-OCI V2 Python package."""

from . import update_schedule as _update_schedule

_update_schedule.register()

# Keep the established updater as the transaction owner while replacing two
# bounded primitives needed by the appliance workflow: exact candidate
# activation and introduction/removal of newly project-owned systemd units.
from . import update as _update
from . import update_activation as _update_activation
from . import update_unit_migration as _update_unit_migration

_update._activate_runtime = _update_activation.activate_runtime
_update._install_units = _update_unit_migration.install_units
_update._restore_units = _update_unit_migration.restore_units

del _update_schedule, _update, _update_activation, _update_unit_migration
