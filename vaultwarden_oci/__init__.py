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

# The appliance orchestrator has a stricter candidate activator than the
# legacy low-level updater. Bind its keyword default without changing the
# legacy apply_update default identity used by the injected test boundary.
from . import update_activation as _update_activation
from . import update_appliance as _update_appliance

if _update_appliance.apply_prepared.__kwdefaults__ is not None:
    _update_appliance.apply_prepared.__kwdefaults__["activator"] = _update_activation.activate_runtime

del _update_schedule, _update, _update_unit_migration, _update_activation, _update_appliance
