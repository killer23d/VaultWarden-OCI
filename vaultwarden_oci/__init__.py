"""VaultWarden-OCI V2 Python package."""

# recovery_ux carries a subprocess-shaped seam for focused unit tests. Make the
# proven V1-compatible password transport the package-level default as well as
# the vwctl/setup entry-point default, so future in-process callers cannot
# accidentally fall back to a less capable transport.
from . import recovery_ux as recovery_ux
from . import sevenzip_secure as sevenzip_secure

recovery_ux._seven = sevenzip_secure.run
