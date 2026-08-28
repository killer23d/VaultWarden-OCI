"""Admin credential transformations at component trust boundaries."""
from __future__ import annotations

import re
import shlex
import subprocess
from typing import Sequence


class AdminCredentialError(RuntimeError):
    """Raised when a protected admin credential cannot be derived safely."""


_ARGON2ID_PHC = re.compile(
    r"^\$argon2id\$v=19\$m=\d+,t=\d+,p=\d+\$[A-Za-z0-9+/]+={0,2}\$[A-Za-z0-9+/]+={0,2}$"
)
_TOKEN_LINE = re.compile(r"ADMIN_TOKEN='([^'\r\n]+)'")


def is_vaultwarden_phc(value: str) -> bool:
    """Return whether value is a canonical Argon2id PHC accepted for ADMIN_TOKEN."""
    return bool(_ARGON2ID_PHC.fullmatch(value))


def _hash_command(image: str) -> list[str]:
    if not image or any(char in image for char in "\0\r\n\t "):
        raise AdminCredentialError("Vaultwarden image reference is invalid")
    # Vaultwarden's supported `hash` command prompts on a TTY. Ubuntu 24.04
    # provides `script(1)` as an essential utility, so use it only as a
    # pseudoterminal boundary. The source secret remains stdin-only and is
    # never placed in argv, environment variables, files, or reported errors.
    child = shlex.join(
        [
            "docker",
            "run",
            "--rm",
            "--interactive",
            "--tty",
            "--network",
            "none",
            "--read-only",
            "--cap-drop",
            "ALL",
            "--security-opt",
            "no-new-privileges:true",
            "--pids-limit",
            "50",
            "--memory",
            "256m",
            "--entrypoint",
            "/vaultwarden",
            image,
            "hash",
            "--preset",
            "bitwarden",
        ]
    )
    return [
        "script",
        "--quiet",
        "--return",
        "--echo",
        "never",
        "--command",
        child,
        "/dev/null",
    ]


def _ensure_image(image: str, *, runner=subprocess.run) -> None:
    """Make the one possible network step explicit before the TTY hash command."""
    try:
        present = runner(
            ["docker", "image", "inspect", image],
            text=True,
            capture_output=True,
            check=False,
            shell=False,
        )
    except OSError as exc:
        raise AdminCredentialError("cannot inspect the exact Vaultwarden image") from exc
    if present.returncode == 0:
        return

    print("INFO: exact Vaultwarden image is not local; pulling it before admin credential derivation.", flush=True)
    try:
        pulled = runner(
            ["docker", "pull", image],
            text=True,
            check=False,
            shell=False,
        )
    except OSError as exc:
        raise AdminCredentialError("cannot pull the exact Vaultwarden image") from exc
    if pulled.returncode != 0:
        raise AdminCredentialError("exact Vaultwarden image pull failed")


def derive_vaultwarden_admin_phc(
    password: str,
    image: str,
    *,
    runner=subprocess.run,
) -> str:
    """Derive a salted Argon2id PHC with the exact pinned Vaultwarden image.

    SOPS/recovery custody retains the operator's high-entropy source secret so
    it remains usable for `/admin`. Only this derived PHC is materialized into
    the Vaultwarden container boundary.
    """
    if (
        not isinstance(password, str)
        or len(password) < 8
        or any(char in password for char in "\0\r\n")
    ):
        raise AdminCredentialError("Vaultwarden admin secret must be a single-line value of at least 8 characters")

    _ensure_image(image, runner=runner)
    argv: Sequence[str] = _hash_command(image)
    try:
        completed = runner(
            list(argv),
            input=password + "\n" + password + "\n",
            text=True,
            capture_output=True,
            check=False,
            shell=False,
        )
    except OSError as exc:
        raise AdminCredentialError("cannot run the Vaultwarden admin-token hash boundary") from exc

    if completed.returncode != 0:
        raise AdminCredentialError("Vaultwarden admin-token hash generation failed")

    match = _TOKEN_LINE.search(completed.stdout.replace("\r", ""))
    if match is None or not is_vaultwarden_phc(match.group(1)):
        raise AdminCredentialError("Vaultwarden admin-token hash generation returned an invalid Argon2id PHC")
    return match.group(1)
